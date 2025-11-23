import Testing
import Foundation

/// Restart Policy Tests
/// Tests Docker restart policies (always, unless-stopped, on-failure, no) by:
/// 1. Creating containers with various restart policies
/// 2. Stopping the daemon
/// 3. Starting the daemon
/// 4. Verifying containers restarted according to their policy
///
/// Prerequisites:
/// - Docker CLI installed
/// - Arca built at .build/debug/Arca
///
/// Note: Tests run serially to avoid race conditions
@Suite("Restart Policies - CLI Integration", .serialized)
struct RestartPolicyTests {

    static let socketPath = "/tmp/arca-test-restart-policy.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-restart-policy-test.log"

    // MARK: - Tests

    @Test("Restart policy 'always' restarts container on daemon restart")
    func restartAlways() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart always
        let containerName = "restart-always-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart always \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        // Wait for it to start
        try await Task.sleep(for: .seconds(1.0))

        // Verify it's running
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "running", "Container should be running before restart")

        // Stop the container (simulating a crash or exit)
        _ = try docker("stop \(containerName)", socketPath: Self.socketPath)

        // Verify it's stopped
        let stateAfterStop = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterStop == "exited", "Container should be exited after stop")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Wait a bit for restart policy to be applied
        try await Task.sleep(for: .seconds(2.0))

        // Verify container auto-restarted
        let stateAfterRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterRestart == "running", "Container with --restart always should auto-restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Restart policy 'unless-stopped' does NOT restart manually stopped container")
    func unlessStoppedManualStop() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart unless-stopped
        let containerName = "restart-unless-stopped-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart unless-stopped \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        try await Task.sleep(for: .seconds(1.0))

        // Verify running
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "running")

        // Manually stop the container (user action)
        _ = try docker("stop \(containerName)", socketPath: Self.socketPath)

        // Verify stopped
        let stateAfterStop = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterStop == "exited")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify container did NOT auto-restart (because it was manually stopped)
        let stateAfterRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterRestart == "exited", "Manually stopped container with unless-stopped should NOT restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Restart policy 'unless-stopped' DOES restart naturally exited container")
    func unlessStoppedNaturalExit() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart unless-stopped that exits naturally
        let containerName = "restart-unless-stopped-natural-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart unless-stopped \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)

        // Wait for it to exit naturally
        try await Task.sleep(for: .seconds(2.0))

        // Verify it exited
        let stateBeforeRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBeforeRestart == "exited", "Container should have exited naturally")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify container DID auto-restart (because it exited naturally, not stopped by user)
        let stateAfterRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterRestart == "running", "Naturally exited container with unless-stopped should restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Restart policy 'on-failure' restarts on non-zero exit code")
    func onFailureRestarts() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart on-failure that exits with error
        let containerName = "restart-on-failure-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart on-failure \(Self.testImage) sh -c 'sleep 1; exit 1'", socketPath: Self.socketPath)

        // Wait for it to exit with error
        try await Task.sleep(for: .seconds(2.0))

        // Verify it exited with non-zero code
        let exitCode = try docker("inspect \(containerName) --format '{{.State.ExitCode}}'", socketPath: Self.socketPath)
        #expect(exitCode == "1", "Container should have exited with code 1")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify container auto-restarted (because exit code was non-zero)
        let stateAfterRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterRestart == "running", "Container with on-failure should restart after non-zero exit")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Restart policy 'on-failure' does NOT restart on zero exit code")
    func onFailureNoRestartOnSuccess() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart on-failure that exits successfully
        let containerName = "restart-on-failure-success-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart on-failure \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)

        // Wait for it to exit
        try await Task.sleep(for: .seconds(2.0))

        // Verify it exited with code 0
        let exitCode = try docker("inspect \(containerName) --format '{{.State.ExitCode}}'", socketPath: Self.socketPath)
        #expect(exitCode == "0", "Container should have exited with code 0")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify container did NOT auto-restart (exit code was 0)
        let stateAfterRestart = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfterRestart == "exited", "Container with on-failure should NOT restart after zero exit code")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Restart policy 'no' never restarts container")
    func noRestartPolicy() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --restart no (default)
        let containerName = "restart-no-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) --restart no \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)

        // Wait for it to exit
        try await Task.sleep(for: .seconds(2.0))

        // Verify it exited
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "exited")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify container did NOT auto-restart
        let stateAfter = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfter == "exited", "Container with --restart no should never restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Multiple containers with different restart policies")
    func mixedRestartPolicies() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970

        // Create containers with different policies
        let alwaysContainer = "restart-mixed-always-\(timestamp)"
        let noContainer = "restart-mixed-no-\(timestamp)"
        let onFailureSuccessContainer = "restart-mixed-onfailure-success-\(timestamp)"
        let onFailureFailContainer = "restart-mixed-onfailure-fail-\(timestamp)"

        _ = try docker("run -d --name \(alwaysContainer) --restart always \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)
        _ = try docker("run -d --name \(noContainer) --restart no \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)
        _ = try docker("run -d --name \(onFailureSuccessContainer) --restart on-failure \(Self.testImage) sh -c 'sleep 1; exit 0'", socketPath: Self.socketPath)
        _ = try docker("run -d --name \(onFailureFailContainer) --restart on-failure \(Self.testImage) sh -c 'sleep 1; exit 1'", socketPath: Self.socketPath)

        // Wait for all to exit
        try await Task.sleep(for: .seconds(2.0))

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Check states
        let alwaysState = try docker("inspect \(alwaysContainer) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let noState = try docker("inspect \(noContainer) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let onFailureSuccessState = try docker("inspect \(onFailureSuccessContainer) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let onFailureFailState = try docker("inspect \(onFailureFailContainer) --format '{{.State.Status}}'", socketPath: Self.socketPath)

        print("States after restart:")
        print("  always: \(alwaysState)")
        print("  no: \(noState)")
        print("  on-failure (exit 0): \(onFailureSuccessState)")
        print("  on-failure (exit 1): \(onFailureFailState)")

        // Verify expected states
        #expect(alwaysState == "running", "Container with --restart always should be running")
        #expect(noState == "exited", "Container with --restart no should be exited")
        #expect(onFailureSuccessState == "exited", "Container with on-failure (exit 0) should be exited")
        #expect(onFailureFailState == "running", "Container with on-failure (exit 1) should be running")

        // Cleanup
        _ = try? docker("rm -f \(alwaysContainer)", socketPath: Self.socketPath)
        _ = try? docker("rm -f \(noContainer)", socketPath: Self.socketPath)
        _ = try? docker("rm -f \(onFailureSuccessContainer)", socketPath: Self.socketPath)
        _ = try? docker("rm -f \(onFailureFailContainer)", socketPath: Self.socketPath)
    }

    @Test("Restart policy persists in database")
    func restartPolicyInDatabase() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with restart policy
        let containerName = "restart-db-test-\(Date().timeIntervalSince1970)"
        _ = try docker("create --name \(containerName) --restart always \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        // Query database for restart policy
        let dbPath = "\(NSHomeDirectory())/.arca/state.db"
        let query = "SELECT host_config_json FROM containers WHERE name = '\(containerName)';"
        let hostConfigJSON = try shell("sqlite3 \(dbPath) \"\(query)\"")

        print("HostConfig JSON: \(hostConfigJSON)")

        // Verify restart policy is in JSON
        #expect(hostConfigJSON.contains("RestartPolicy"), "HostConfig should contain RestartPolicy")
        #expect(hostConfigJSON.contains("always"), "RestartPolicy should be 'always'")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }
}


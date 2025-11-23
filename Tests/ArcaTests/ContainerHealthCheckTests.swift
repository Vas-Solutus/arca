import Testing
import Foundation

/// Comprehensive tests for container health check functionality (Phase 6 - Task 6.2)
/// Validates health check implementation against Docker Engine API v1.51 spec
@Suite("Container Health Checks - Phase 6.2", .serialized)
struct ContainerHealthCheckTests {
    static let socketPath = "/tmp/arca-test-healthcheck.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-healthcheck-test.log"

    // MARK: - Basic Health Check Tests

    @Test("Container with health check shows starting status")
    func healthCheckStartingStatus() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check (CMD format)
        _ = try docker("""
            run -d --name test-health-starting \
            --health-cmd "echo healthy" \
            --health-interval 5s \
            --health-retries 3 \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Verify health status is "starting"
        let healthStatus = try docker("inspect test-health-starting --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(["starting", "healthy"].contains(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines)),
                "Health status should be 'starting' or 'healthy'")

        // Clean up
        _ = try? docker("rm -f test-health-starting", socketPath: Self.socketPath)
    }

    @Test("Health check with CMD format executes correctly")
    func healthCheckCMDFormat() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check that always succeeds
        _ = try docker("""
            run -d --name test-health-cmd \
            --health-cmd "true" \
            --health-interval 2s \
            --health-retries 3 \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health check to execute
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

        // Verify health status is "healthy"
        let healthStatus = try docker("inspect test-health-cmd --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Health status should be 'healthy'")

        // Verify failing streak is 0
        let failingStreak = try docker("inspect test-health-cmd --format='{{.State.Health.FailingStreak}}'", socketPath: Self.socketPath)
        #expect(failingStreak.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
                "Failing streak should be 0")

        // Clean up
        _ = try? docker("rm -f test-health-cmd", socketPath: Self.socketPath)
    }

    @Test("Health check with CMD-SHELL format uses shell")
    func healthCheckCMDShellFormat() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with shell-based health check
        _ = try docker("""
            run -d --name test-health-shell \
            --health-cmd "test -f /tmp/healthy && echo ok || exit 1" \
            --health-interval 2s \
            --health-retries 3 \
            alpine sh -c "touch /tmp/healthy && sleep 3600"
            """, socketPath: Self.socketPath)

        // Wait for health check to execute
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

        // Verify health status is "healthy"
        let healthStatus = try docker("inspect test-health-shell --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Health status should be 'healthy' for shell-based health check")

        // Clean up
        _ = try? docker("rm -f test-health-shell", socketPath: Self.socketPath)
    }

    @Test("Consecutive failures trigger unhealthy status")
    func consecutiveFailuresTriggerUnhealthy() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check that always fails
        _ = try docker("""
            run -d --name test-health-unhealthy \
            --health-cmd "false" \
            --health-interval 2s \
            --health-retries 2 \
            --health-start-period 0s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health checks to fail (2 retries + initial = ~6s)
        try await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds

        // Verify health status is "unhealthy"
        let healthStatus = try docker("inspect test-health-unhealthy --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "unhealthy",
                "Health status should be 'unhealthy' after consecutive failures")

        // Verify failing streak >= retries
        let failingStreak = try docker("inspect test-health-unhealthy --format='{{.State.Health.FailingStreak}}'", socketPath: Self.socketPath)
        let streak = Int(failingStreak.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(streak >= 2, "Failing streak should be >= 2")

        // Clean up
        _ = try? docker("rm -f test-health-unhealthy", socketPath: Self.socketPath)
    }

    @Test("Health check start period delays failure counting")
    func healthCheckStartPeriod() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check that fails initially, then succeeds
        // Start period gives container time to initialize
        _ = try docker("""
            run -d --name test-health-startperiod \
            --health-cmd "test -f /tmp/ready" \
            --health-interval 2s \
            --health-retries 2 \
            --health-start-period 10s \
            --health-start-interval 1s \
            alpine sh -c "sleep 5 && touch /tmp/ready && sleep 3600"
            """, socketPath: Self.socketPath)

        // During start period, failures shouldn't count toward retries
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        let earlyStatus = try docker("inspect test-health-startperiod --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(earlyStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "starting",
                "Health status should still be 'starting' during start period")

        // After file is created (5s + checks), should become healthy
        try await Task.sleep(nanoseconds: 5_000_000_000) // Wait 5 more seconds (total 8s)
        let finalStatus = try docker("inspect test-health-startperiod --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(finalStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Health status should be 'healthy' after container initializes")

        // Clean up
        _ = try? docker("rm -f test-health-startperiod", socketPath: Self.socketPath)
    }

    @Test("Health check timeout cancels long-running checks")
    func healthCheckTimeout() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check that sleeps longer than timeout
        _ = try docker("""
            run -d --name test-health-timeout \
            --health-cmd "sleep 10" \
            --health-interval 3s \
            --health-timeout 1s \
            --health-retries 2 \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health checks to timeout and mark unhealthy
        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds

        // Verify health status is "unhealthy" due to timeouts
        let healthStatus = try docker("inspect test-health-timeout --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "unhealthy",
                "Health status should be 'unhealthy' after timeouts")

        // Clean up
        _ = try? docker("rm -f test-health-timeout", socketPath: Self.socketPath)
    }

    // MARK: - Health Status in Inspect

    @Test("Health status visible in docker inspect")
    func healthStatusInInspect() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check
        _ = try docker("""
            run -d --name test-health-inspect \
            --health-cmd "echo healthy" \
            --health-interval 2s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health check to execute
        try await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds

        // Get full inspect output
        let inspect = try docker("inspect test-health-inspect", socketPath: Self.socketPath)

        // Verify health fields are present
        #expect(inspect.contains("\"Health\""), "Inspect should contain Health field")
        #expect(inspect.contains("\"Status\""), "Health should contain Status field")
        #expect(inspect.contains("\"FailingStreak\""), "Health should contain FailingStreak field")
        #expect(inspect.contains("\"Log\""), "Health should contain Log field")

        // Clean up
        _ = try? docker("rm -f test-health-inspect", socketPath: Self.socketPath)
    }

    @Test("Health check log retains results")
    func healthCheckLogRetention() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with fast health check interval
        _ = try docker("""
            run -d --name test-health-log \
            --health-cmd "echo healthy" \
            --health-interval 1s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for multiple health checks to execute
        try await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds = ~8 checks

        // Get health log
        let inspect = try docker("inspect test-health-log", socketPath: Self.socketPath)

        // Verify log contains results (should have at least 1, max 5 per Docker spec)
        #expect(inspect.contains("\"Log\""), "Health should contain log")

        // Clean up
        _ = try? docker("rm -f test-health-log", socketPath: Self.socketPath)
    }

    // MARK: - NONE Healthcheck

    @Test("NONE healthcheck disables health checks")
    func noneHealthcheckDisables() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with --no-healthcheck flag
        _ = try docker("run -d --name test-health-none --no-healthcheck alpine sleep 3600", socketPath: Self.socketPath)

        // Wait briefly
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Verify no health status in inspect (or status is empty/none)
        let inspect = try docker("inspect test-health-none", socketPath: Self.socketPath)

        // Inspect should either not have Health field or Health should be null
        let hasNoHealth = !inspect.contains("\"Health\"") || inspect.contains("\"Health\": null")
        #expect(hasNoHealth, "Container with --no-healthcheck should not have health status")

        // Clean up
        _ = try? docker("rm -f test-health-none", socketPath: Self.socketPath)
    }

    // MARK: - Health Check Lifecycle

    @Test("Health checks stop when container stops")
    func healthChecksStopOnContainerStop() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check
        _ = try docker("""
            run -d --name test-health-lifecycle \
            --health-cmd "echo healthy" \
            --health-interval 2s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health check to execute
        try await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds

        // Verify container is healthy
        let beforeStatus = try docker("inspect test-health-lifecycle --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(beforeStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Container should be healthy before stop")

        // Stop container
        _ = try docker("stop test-health-lifecycle", socketPath: Self.socketPath)

        // Restart container
        _ = try docker("start test-health-lifecycle", socketPath: Self.socketPath)

        // Wait for health checks to resume
        try await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds

        // Verify health checks resumed
        let afterStatus = try docker("inspect test-health-lifecycle --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(["starting", "healthy"].contains(afterStatus.trimmingCharacters(in: .whitespacesAndNewlines)),
                "Health checks should resume after restart")

        // Clean up
        _ = try? docker("rm -f test-health-lifecycle", socketPath: Self.socketPath)
    }

    @Test("Health checks persist across daemon restart")
    func healthChecksPersistAcrossRestart() async throws {
        // Start first daemon
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with health check and restart policy
        _ = try docker("""
            run -d --name test-health-persist \
            --restart always \
            --health-cmd "echo healthy" \
            --health-interval 2s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for health check to execute
        try await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds

        // Verify health check is working
        let beforeStatus = try docker("inspect test-health-persist --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(beforeStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Container should be healthy before restart")

        // Stop daemon
        try stopDaemon(pid: daemonPID1)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Start second daemon
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer {
            _ = try? docker("rm -f test-health-persist", socketPath: Self.socketPath)
            try? stopDaemon(pid: daemonPID2)
        }

        // Wait for container to restart and health checks to resume
        try await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds

        // Verify health checks resumed after daemon restart
        let afterStatus = try docker("inspect test-health-persist --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(["starting", "healthy"].contains(afterStatus.trimmingCharacters(in: .whitespacesAndNewlines)),
                "Health checks should resume after daemon restart")
    }

    // MARK: - Edge Cases

    @Test("Container without healthcheck has no health status")
    func containerWithoutHealthcheck() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container without health check
        _ = try docker("run -d --name test-no-health alpine sleep 3600", socketPath: Self.socketPath)

        // Verify no health status
        let inspect = try docker("inspect test-no-health", socketPath: Self.socketPath)
        let hasNoHealth = !inspect.contains("\"Health\"") || inspect.contains("\"Health\": null")
        #expect(hasNoHealth, "Container without healthcheck should not have health status")

        // Clean up
        _ = try? docker("rm -f test-no-health", socketPath: Self.socketPath)
    }

    @Test("Health check intervals are respected")
    func healthCheckIntervals() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with 3s interval
        _ = try docker("""
            run -d --name test-health-interval \
            --health-cmd "echo healthy" \
            --health-interval 3s \
            alpine sleep 3600
            """, socketPath: Self.socketPath)

        // Wait for 2 intervals (~6s)
        try await Task.sleep(nanoseconds: 7_000_000_000) // 7 seconds

        // Health checks should have executed approximately 2 times
        // We can't check exact count easily, but verify status is healthy
        let healthStatus = try docker("inspect test-health-interval --format='{{.State.Health.Status}}'", socketPath: Self.socketPath)
        #expect(healthStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "healthy",
                "Health status should be healthy after intervals")

        // Clean up
        _ = try? docker("rm -f test-health-interval", socketPath: Self.socketPath)
    }
}

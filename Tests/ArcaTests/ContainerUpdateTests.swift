import Testing
import Foundation

/// Tests for Container Update Endpoint (Phase 6 - Task 6.1)
/// Validates POST /containers/{id}/update endpoint against Docker Engine API v1.51 spec
@Suite("Container Update API - Phase 6.1", .serialized)
struct ContainerUpdateTests {
    static let socketPath = "/tmp/arca-test-container-update.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-container-update-test.log"

    // MARK: - Memory Limit Updates

    @Test("Update container memory limit")
    func updateMemoryLimit() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-memory alpine sleep 3600", socketPath: Self.socketPath)

        // Verify initial memory is 0 (unlimited)
        let initialInspect = try docker("inspect test-update-memory --format='{{.HostConfig.Memory}}'", socketPath: Self.socketPath)
        #expect(initialInspect.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "Initial memory should be 0 (unlimited)")

        // Update memory to 512MB
        _ = try docker("update --memory 512m test-update-memory", socketPath: Self.socketPath)

        // Verify memory was updated
        let updatedInspect = try docker("inspect test-update-memory --format='{{.HostConfig.Memory}}'", socketPath: Self.socketPath)
        let updatedMemory = Int(updatedInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(updatedMemory == 536870912, "Memory should be updated to 536870912 (512MB)")

        // Clean up
        _ = try? docker("rm -f test-update-memory", socketPath: Self.socketPath)
    }

    @Test("Update container memory reservation")
    func updateMemoryReservation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-memres alpine sleep 3600", socketPath: Self.socketPath)

        // Update memory reservation to 256MB
        _ = try docker("update --memory-reservation 256m test-update-memres", socketPath: Self.socketPath)

        // Verify memory reservation was updated
        let updatedInspect = try docker("inspect test-update-memres --format='{{.HostConfig.MemoryReservation}}'", socketPath: Self.socketPath)
        let updatedMemRes = Int(updatedInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(updatedMemRes == 268435456, "Memory reservation should be updated to 268435456 (256MB)")

        // Clean up
        _ = try? docker("rm -f test-update-memres", socketPath: Self.socketPath)
    }

    // MARK: - CPU Limit Updates

    @Test("Update container CPU shares")
    func updateCPUShares() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-cpu alpine sleep 3600", socketPath: Self.socketPath)

        // Update CPU shares to 512
        _ = try docker("update --cpu-shares 512 test-update-cpu", socketPath: Self.socketPath)

        // Verify CPU shares were updated
        let updatedInspect = try docker("inspect test-update-cpu --format='{{.HostConfig.CpuShares}}'", socketPath: Self.socketPath)
        let updatedShares = Int(updatedInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(updatedShares == 512, "CPU shares should be updated to 512")

        // Clean up
        _ = try? docker("rm -f test-update-cpu", socketPath: Self.socketPath)
    }

    @Test("Update container CPU quota and period")
    func updateCPUQuotaPeriod() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-cpu-quota alpine sleep 3600", socketPath: Self.socketPath)

        // Update CPU quota to 50000 and period to 100000 (0.5 CPUs)
        _ = try docker("update --cpu-quota 50000 --cpu-period 100000 test-update-cpu-quota", socketPath: Self.socketPath)

        // Verify CPU quota and period were updated
        let quotaInspect = try docker("inspect test-update-cpu-quota --format='{{.HostConfig.CpuQuota}}'", socketPath: Self.socketPath)
        let periodInspect = try docker("inspect test-update-cpu-quota --format='{{.HostConfig.CpuPeriod}}'", socketPath: Self.socketPath)

        let updatedQuota = Int(quotaInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let updatedPeriod = Int(periodInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        #expect(updatedQuota == 50000, "CPU quota should be updated to 50000")
        #expect(updatedPeriod == 100000, "CPU period should be updated to 100000")

        // Clean up
        _ = try? docker("rm -f test-update-cpu-quota", socketPath: Self.socketPath)
    }

    // MARK: - Restart Policy Updates

    @Test("Update container restart policy")
    func updateRestartPolicy() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with no restart policy
        _ = try docker("run -d --name test-update-restart alpine sleep 3600", socketPath: Self.socketPath)

        // Verify initial restart policy is "no"
        let initialInspect = try docker("inspect test-update-restart --format='{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)
        #expect(initialInspect.trimmingCharacters(in: .whitespacesAndNewlines) == "no", "Initial restart policy should be 'no'")

        // Update restart policy to "always"
        _ = try docker("update --restart always test-update-restart", socketPath: Self.socketPath)

        // Verify restart policy was updated
        let updatedInspect = try docker("inspect test-update-restart --format='{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)
        #expect(updatedInspect.trimmingCharacters(in: .whitespacesAndNewlines) == "always", "Restart policy should be updated to 'always'")

        // Clean up
        _ = try? docker("rm -f test-update-restart", socketPath: Self.socketPath)
    }

    @Test("Update restart policy with max retry count")
    func updateRestartPolicyWithRetries() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-restart-retry alpine sleep 3600", socketPath: Self.socketPath)

        // Update restart policy to "on-failure" with 3 retries
        _ = try docker("update --restart on-failure:3 test-update-restart-retry", socketPath: Self.socketPath)

        // Verify restart policy and max retry count
        let policyInspect = try docker("inspect test-update-restart-retry --format='{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)
        let retriesInspect = try docker("inspect test-update-restart-retry --format='{{.HostConfig.RestartPolicy.MaximumRetryCount}}'", socketPath: Self.socketPath)

        #expect(policyInspect.trimmingCharacters(in: .whitespacesAndNewlines) == "on-failure", "Restart policy should be 'on-failure'")

        let retries = Int(retriesInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(retries == 3, "Max retry count should be 3")

        // Clean up
        _ = try? docker("rm -f test-update-restart-retry", socketPath: Self.socketPath)
    }

    // MARK: - Multiple Updates

    @Test("Update multiple resource limits at once")
    func updateMultipleLimits() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        _ = try docker("run -d --name test-update-multi alpine sleep 3600", socketPath: Self.socketPath)

        // Update multiple limits at once
        _ = try docker("update --memory 1g --cpu-shares 1024 --restart always test-update-multi", socketPath: Self.socketPath)

        // Verify all updates
        let memoryInspect = try docker("inspect test-update-multi --format='{{.HostConfig.Memory}}'", socketPath: Self.socketPath)
        let sharesInspect = try docker("inspect test-update-multi --format='{{.HostConfig.CpuShares}}'", socketPath: Self.socketPath)
        let restartInspect = try docker("inspect test-update-multi --format='{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)

        let memory = Int(memoryInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let shares = Int(sharesInspect.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        #expect(memory == 1073741824, "Memory should be updated to 1073741824 (1GB)")
        #expect(shares == 1024, "CPU shares should be updated to 1024")
        #expect(restartInspect.trimmingCharacters(in: .whitespacesAndNewlines) == "always", "Restart policy should be 'always'")

        // Clean up
        _ = try? docker("rm -f test-update-multi", socketPath: Self.socketPath)
    }

    // MARK: - Persistence Tests

    @Test("Updated limits persist across daemon restart")
    func updatesPersistAcrossRestart() async throws {
        // Start first daemon
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container and update limits
        _ = try docker("run -d --name test-update-persist alpine sleep 3600", socketPath: Self.socketPath)
        _ = try docker("update --memory 512m --cpu-shares 512 --restart always test-update-persist", socketPath: Self.socketPath)

        // Verify updates before restart
        let memoryBefore = try docker("inspect test-update-persist --format='{{.HostConfig.Memory}}'", socketPath: Self.socketPath)
        let sharesBefore = try docker("inspect test-update-persist --format='{{.HostConfig.CpuShares}}'", socketPath: Self.socketPath)

        // Stop daemon
        try stopDaemon(pid: daemonPID1)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Start second daemon
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer {
            _ = try? docker("rm -f test-update-persist", socketPath: Self.socketPath)
            try? stopDaemon(pid: daemonPID2)
        }

        // Verify updates persisted after restart
        let memoryAfter = try docker("inspect test-update-persist --format='{{.HostConfig.Memory}}'", socketPath: Self.socketPath)
        let sharesAfter = try docker("inspect test-update-persist --format='{{.HostConfig.CpuShares}}'", socketPath: Self.socketPath)
        let restartAfter = try docker("inspect test-update-persist --format='{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)

        #expect(memoryBefore == memoryAfter, "Memory limit should persist across restart")
        #expect(sharesBefore == sharesAfter, "CPU shares should persist across restart")
        #expect(restartAfter.trimmingCharacters(in: .whitespacesAndNewlines) == "always", "Restart policy should persist")
    }

    // MARK: - Error Cases

    @Test("Update non-existent container returns 404")
    func updateNonExistentContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Try to update non-existent container
        let failed = dockerExpectFailure("update --memory 512m nonexistent", socketPath: Self.socketPath)
        #expect(failed, "Updating non-existent container should fail")
    }

    @Test("Update with invalid memory reservation (greater than memory) returns validation error")
    func updateInvalidMemoryReservation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with memory limit
        _ = try docker("run -d --name test-invalid-memres --memory 512m alpine sleep 3600", socketPath: Self.socketPath)

        // Try to update memory reservation to be greater than memory limit
        let failed = dockerExpectFailure("update --memory-reservation 1g test-invalid-memres", socketPath: Self.socketPath)
        #expect(failed, "Setting memory reservation > memory should fail")

        // Clean up
        _ = try? docker("rm -f test-invalid-memres", socketPath: Self.socketPath)
    }
}

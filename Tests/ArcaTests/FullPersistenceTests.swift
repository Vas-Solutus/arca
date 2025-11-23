import Testing
import Foundation

/// Full Persistence Integration Tests
/// Tests complete persistence flow with networks, containers, restart policies, and volumes by:
/// 1. Creating networks, volumes, and containers with various configurations
/// 2. Stopping the daemon
/// 3. Starting the daemon
/// 4. Verifying all state persisted and auto-restart worked correctly
///
/// Prerequisites:
/// - Docker CLI installed
/// - Arca built at .build/debug/Arca
///
/// Note: Tests run serially to avoid race conditions
@Suite("Full Persistence Integration - CLI Integration", .serialized)
struct FullPersistenceTests {

    static let socketPath = "/tmp/arca-test-full-persistence.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-full-persistence-test.log"

    // MARK: - Complete Persistence Flow Tests

    @Test("Complete persistence flow: networks + containers + restart policies")
    func completePersistenceFlow() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let networkName = "test-network-\(timestamp)"
        let container1 = "persist-c1-\(timestamp)"
        let container2 = "persist-c2-\(timestamp)"

        // Create custom network
        _ = try docker("network create \(networkName)", socketPath: Self.socketPath)

        // Create containers with different restart policies on custom network
        _ = try docker("run -d --name \(container1) --restart always --network \(networkName) \(Self.testImage) sleep 3600", socketPath: Self.socketPath)
        _ = try docker("run -d --name \(container2) --restart unless-stopped --network \(networkName) \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        try await Task.sleep(for: .seconds(2.0))

        // Verify both running
        let state1Before = try docker("inspect \(container1) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let state2Before = try docker("inspect \(container2) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(state1Before == "running", "Container 1 should be running")
        #expect(state2Before == "running", "Container 2 should be running")

        // Verify network attachments
        let network1Before = try docker("inspect \(container1) --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}'", socketPath: Self.socketPath)
        #expect(network1Before.contains(networkName), "Container 1 should be on \(networkName)")

        // Stop container 2 manually (so unless-stopped won't restart it)
        _ = try docker("stop \(container2)", socketPath: Self.socketPath)

        // Verify network still exists
        let networksBefore = try docker("network ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(networksBefore.contains(networkName), "Network should exist before restart")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(3.0))

        // Verify network persisted
        let networksAfter = try docker("network ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(networksAfter.contains(networkName), "Network should persist after restart")

        // Verify containers exist
        let containersAfter = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(containersAfter.contains(container1), "Container 1 should exist")
        #expect(containersAfter.contains(container2), "Container 2 should exist")

        // Verify restart policies applied correctly
        let state1After = try docker("inspect \(container1) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let state2After = try docker("inspect \(container2) --format '{{.State.Status}}'", socketPath: Self.socketPath)

        #expect(state1After == "running", "Container 1 with --restart always should auto-restart")
        #expect(state2After == "exited", "Container 2 with --restart unless-stopped should NOT restart (was manually stopped)")

        // Verify network attachments persisted
        let network1After = try docker("inspect \(container1) --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}'", socketPath: Self.socketPath)
        #expect(network1After.contains(networkName), "Container 1 should still be on \(networkName) after restart")

        // Cleanup
        _ = try? docker("rm -f \(container1)", socketPath: Self.socketPath)
        _ = try? docker("rm -f \(container2)", socketPath: Self.socketPath)
        _ = try? docker("network rm \(networkName)", socketPath: Self.socketPath)
    }

    @Test("Restart policies work with network attachments")
    func restartPolicyWithNetworkAttachment() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let networkName = "test-net-restart-\(timestamp)"
        let containerName = "container-net-restart-\(timestamp)"

        // Create network and container
        _ = try docker("network create \(networkName)", socketPath: Self.socketPath)
        _ = try docker("run -d --name \(containerName) --restart always --network \(networkName) \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        try await Task.sleep(for: .seconds(2.0))

        // Verify running and on network
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "running")

        let networkBefore = try docker("inspect \(containerName) --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}'", socketPath: Self.socketPath)
        #expect(networkBefore.contains(networkName))

        // Get IP address before restart
        let ipBefore = try docker("inspect \(containerName) --format '{{.NetworkSettings.Networks.\(networkName).IPAddress}}'", socketPath: Self.socketPath)
        print("IP before restart: \(ipBefore)")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(3.0))

        // Verify container auto-restarted on correct network
        let stateAfter = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfter == "running", "Container should auto-restart")

        let networkAfter = try docker("inspect \(containerName) --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}'", socketPath: Self.socketPath)
        #expect(networkAfter.contains(networkName), "Container should be on correct network after restart")

        // Get IP address after restart (should be same due to IPAM persistence)
        let ipAfter = try docker("inspect \(containerName) --format '{{.NetworkSettings.Networks.\(networkName).IPAddress}}'", socketPath: Self.socketPath)
        print("IP after restart: \(ipAfter)")
        #expect(ipBefore == ipAfter, "IP address should be preserved after restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
        _ = try? docker("network rm \(networkName)", socketPath: Self.socketPath)
    }

    @Test("Named volumes persist across daemon restart")
    func namedVolumesPersist() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let volumeName = "test-volume-\(timestamp)"
        let containerName = "container-volume-\(timestamp)"

        // Create named volume
        _ = try docker("volume create \(volumeName)", socketPath: Self.socketPath)

        // Create container with volume
        _ = try docker("create --name \(containerName) -v \(volumeName):/data \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        // Verify volume exists before restart
        let volumesBefore = try docker("volume ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(volumesBefore.contains(volumeName), "Volume should exist before restart")

        // Verify container has mount
        let mountsBefore = try docker("inspect \(containerName) --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{end}}'", socketPath: Self.socketPath)
        #expect(mountsBefore.contains(volumeName), "Container should have volume mount")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify volume persisted
        let volumesAfter = try docker("volume ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(volumesAfter.contains(volumeName), "Volume should persist after restart")

        // Verify container persisted with mount
        let containersAfter = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(containersAfter.contains(containerName), "Container should persist")

        let mountsAfter = try docker("inspect \(containerName) --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{end}}'", socketPath: Self.socketPath)
        #expect(mountsAfter.contains(volumeName), "Container mount should persist")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
        _ = try? docker("volume rm \(volumeName)", socketPath: Self.socketPath)
    }

    @Test("Anonymous volumes cleanup on container removal")
    func anonymousVolumesCleanup() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let containerName = "container-anon-volume-\(timestamp)"

        // Create container with anonymous volume
        _ = try docker("run --name \(containerName) -v /data \(Self.testImage) echo test", socketPath: Self.socketPath)

        // Find the anonymous volume
        let mounts = try docker("inspect \(containerName) --format '{{range .Mounts}}{{.Name}}{{end}}'", socketPath: Self.socketPath)
        print("Anonymous volume: \(mounts)")

        // Verify volume exists
        let volumesBefore = try docker("volume ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(volumesBefore.contains(mounts), "Anonymous volume should exist")

        // Remove container
        _ = try docker("rm \(containerName)", socketPath: Self.socketPath)

        // Verify anonymous volume was deleted
        let volumesAfter = try docker("volume ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(!volumesAfter.contains(mounts), "Anonymous volume should be deleted with container")
    }

    // MARK: - Edge Case Tests

    @Test("Network deleted while containers attached - orphaned attachments handled")
    func networkDeletedWithAttachedContainers() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let networkName = "test-net-orphan-\(timestamp)"
        let containerName = "container-orphan-\(timestamp)"

        // Create network and container
        _ = try docker("network create \(networkName)", socketPath: Self.socketPath)
        _ = try docker("create --name \(containerName) --network \(networkName) \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        // Try to remove network (should fail - container attached)
        let networkDeletionFailed = dockerExpectFailure("network rm \(networkName)", socketPath: Self.socketPath)
        #expect(networkDeletionFailed, "Network removal should have failed with attached containers")

        // Remove container first
        _ = try docker("rm \(containerName)", socketPath: Self.socketPath)

        // Now network removal should succeed
        _ = try docker("network rm \(networkName)", socketPath: Self.socketPath)

        // Verify network is gone
        let networks = try docker("network ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(!networks.contains(networkName), "Network should be removed")
    }

    @Test("Container running when daemon crashes - graceful recovery")
    func containerRunningDuringCrash() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let containerName = "container-crash-recovery-\(timestamp)"

        // Create long-running container
        _ = try docker("run -d --name \(containerName) \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        try await Task.sleep(for: .seconds(2.0))

        // Verify running
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "running")

        // Simulate crash (SIGKILL instead of graceful SIGTERM)
        kill(currentPid, SIGKILL)
        try await Task.sleep(for: .seconds(1.0))

        // Restart daemon
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Container should be marked as exited with exit code 137 (SIGKILL)
        let stateAfter = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let exitCode = try docker("inspect \(containerName) --format '{{.State.ExitCode}}'", socketPath: Self.socketPath)

        #expect(stateAfter == "exited", "Container should be marked as exited after crash")
        #expect(exitCode == "137", "Exit code should be 137 (SIGKILL) for crash recovery")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Multiple networks with overlapping subnet allocation")
    func multipleNetworksSubnetAllocation() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        let timestamp = Date().timeIntervalSince1970
        let net1 = "test-net1-\(timestamp)"
        let net2 = "test-net2-\(timestamp)"
        let net3 = "test-net3-\(timestamp)"

        // Create multiple networks (should get sequential subnets)
        _ = try docker("network create \(net1)", socketPath: Self.socketPath)
        _ = try docker("network create \(net2)", socketPath: Self.socketPath)
        _ = try docker("network create \(net3)", socketPath: Self.socketPath)

        // Get subnets
        let subnet1 = try docker("inspect \(net1) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)
        let subnet2 = try docker("inspect \(net2) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)
        let subnet3 = try docker("inspect \(net3) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)

        print("Subnets: \(subnet1), \(subnet2), \(subnet3)")

        // Verify all different
        #expect(subnet1 != subnet2, "Subnet 1 and 2 should be different")
        #expect(subnet2 != subnet3, "Subnet 2 and 3 should be different")
        #expect(subnet1 != subnet3, "Subnet 1 and 3 should be different")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(2.0))

        // Verify subnets persisted
        let subnet1After = try docker("inspect \(net1) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)
        let subnet2After = try docker("inspect \(net2) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)
        let subnet3After = try docker("inspect \(net3) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)

        #expect(subnet1 == subnet1After, "Network 1 subnet should persist")
        #expect(subnet2 == subnet2After, "Network 2 subnet should persist")
        #expect(subnet3 == subnet3After, "Network 3 subnet should persist")

        // Create new network after restart (should get next available subnet)
        let net4 = "test-net4-\(timestamp)"
        _ = try docker("network create \(net4)", socketPath: Self.socketPath)
        let subnet4 = try docker("inspect \(net4) --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'", socketPath: Self.socketPath)

        #expect(subnet4 != subnet1, "New network should have different subnet")
        #expect(subnet4 != subnet2, "New network should have different subnet")
        #expect(subnet4 != subnet3, "New network should have different subnet")

        // Cleanup
        _ = try? docker("network rm \(net1)", socketPath: Self.socketPath)
        _ = try? docker("network rm \(net2)", socketPath: Self.socketPath)
        _ = try? docker("network rm \(net3)", socketPath: Self.socketPath)
        _ = try? docker("network rm \(net4)", socketPath: Self.socketPath)
    }

    @Test("Control plane container hidden from docker ps")
    func controlPlaneHiddenFromPS() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        // List all containers
        let allContainers = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)

        // Control plane should NOT appear in regular docker ps
        #expect(!allContainers.contains("arca-control-plane"), "Control plane should be hidden from docker ps")

        // Control plane SHOULD appear with label filter
        let internalContainers = try docker("ps -a --filter label=com.arca.internal --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(internalContainers.contains("arca-control-plane"), "Control plane should appear with label filter")

        // Verify control plane has correct labels
        let labels = try docker("inspect arca-control-plane --format '{{.Config.Labels}}'", socketPath: Self.socketPath)
        #expect(labels.contains("com.arca.internal"), "Control plane should have internal label")
        #expect(labels.contains("com.arca.role"), "Control plane should have role label")
    }

    @Test("Control plane auto-restarts via restart policy")
    func controlPlaneAutoRestarts() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        // Verify control plane is running
        let stateBefore = try docker("inspect arca-control-plane --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateBefore == "running", "Control plane should be running")

        // Verify it has restart policy
        let restartPolicy = try docker("inspect arca-control-plane --format '{{.HostConfig.RestartPolicy.Name}}'", socketPath: Self.socketPath)
        #expect(restartPolicy == "always", "Control plane should have --restart always")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        try await Task.sleep(for: .seconds(3.0))

        // Control plane should auto-restart
        let stateAfter = try docker("inspect arca-control-plane --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(stateAfter == "running", "Control plane should auto-restart via restart policy")
    }

    @Test("Volume in use cannot be deleted")
    func volumeInUseProtection() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        let timestamp = Date().timeIntervalSince1970
        let volumeName = "test-volume-inuse-\(timestamp)"
        let containerName = "container-volume-inuse-\(timestamp)"

        // Create volume and container using it
        _ = try docker("volume create \(volumeName)", socketPath: Self.socketPath)
        _ = try docker("create --name \(containerName) -v \(volumeName):/data \(Self.testImage) sleep 3600", socketPath: Self.socketPath)

        // Try to delete volume (should fail - in use)
        let volumeDeletionFailed = dockerExpectFailure("volume rm \(volumeName)", socketPath: Self.socketPath)
        #expect(volumeDeletionFailed, "Volume deletion should have failed (volume in use)")

        // Remove container
        _ = try docker("rm \(containerName)", socketPath: Self.socketPath)

        // Now volume deletion should succeed
        _ = try docker("volume rm \(volumeName)", socketPath: Self.socketPath)

        // Verify volume is gone
        let volumes = try docker("volume ls --format '{{.Name}}'", socketPath: Self.socketPath)
        #expect(!volumes.contains(volumeName), "Volume should be removed")
    }
}


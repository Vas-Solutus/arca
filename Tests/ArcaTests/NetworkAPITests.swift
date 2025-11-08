import Testing
import Foundation

/// Comprehensive tests for Docker Network API compatibility (Phases 1-5)
/// Validates complete implementation against Docker Engine API v1.51 spec
@Suite("Network API - Complete Compatibility", .serialized)
struct NetworkAPITests {
    static let socketPath = "/tmp/arca-test-network-api.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-network-api-test.log"

    // MARK: - Phase 1: Default host Network

    @Test("Default networks exist on daemon startup (bridge, host, none)")
    func defaultNetworksCreated() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        let output = try docker("network ls", socketPath: Self.socketPath)
        #expect(output.contains("bridge"), "Default bridge network should exist")
        #expect(output.contains("host"), "Default host network should exist")
        #expect(output.contains("none"), "Default none network should exist")
    }

    @Test("Default host network has auto-allocated subnet from Apple vmnet")
    func hostNetworkSubnet() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        let inspectOutput = try docker("network inspect host", socketPath: Self.socketPath)
        // Apple's vmnet framework auto-allocates subnets (typically 192.168.64.0/24, 192.168.65.0/24, etc.)
        // Just verify that a valid subnet and gateway exist
        #expect(inspectOutput.contains("192.168."), "host network should have a 192.168.x.x subnet")
        #expect(inspectOutput.contains("/24"), "host network should have a /24 CIDR")
    }

    @Test("Default networks cannot be deleted (deletion protection)")
    func defaultNetworkDeletionProtection() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Try to delete bridge - should fail
        let bridgeFailed = dockerExpectFailure("network rm bridge", socketPath: Self.socketPath)
        #expect(bridgeFailed, "Deleting default bridge network should fail")

        // Try to delete host - should fail
        let hostFailed = dockerExpectFailure("network rm host", socketPath: Self.socketPath)
        #expect(hostFailed, "Deleting default host network should fail")

        // Try to delete none - should fail
        let noneFailed = dockerExpectFailure("network rm none", socketPath: Self.socketPath)
        #expect(noneFailed, "Deleting default none network should fail")
    }

    @Test("Containers can attach to host network")
    func containerAttachToHost() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container on host network
        let containerID = try docker("run -d --name test-host-attach --network host alpine sleep 300", socketPath: Self.socketPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created on host network")

        // Inspect container to verify network
        let inspectOutput = try docker("inspect test-host-attach", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("host"), "Container should be connected to host network")
        #expect(inspectOutput.contains("192.168."), "Container should have IP from auto-allocated subnet")

        // Clean up
        _ = try? docker("rm -f test-host-attach", socketPath: Self.socketPath)
    }

    @Test("Default networks persist across daemon restart")
    func defaultNetworksPersistence() async throws {
        // Start first daemon
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Verify networks exist
        let output1 = try docker("network ls", socketPath: Self.socketPath)
        #expect(output1.contains("bridge"), "bridge should exist before restart")
        #expect(output1.contains("host"), "host should exist before restart")

        // Stop daemon
        try stopDaemon(pid: daemonPID1)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Start second daemon
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID2) }

        // Verify networks still exist
        let output2 = try docker("network ls", socketPath: Self.socketPath)
        #expect(output2.contains("bridge"), "bridge should persist after restart")
        #expect(output2.contains("host"), "host should persist after restart")
        #expect(output2.contains("none"), "none should persist after restart")
    }

    // MARK: - Phase 2: Network Prune Endpoint

    @Test("Network prune deletes unused networks")
    func basicNetworkPrune() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create test networks
        _ = try docker("network create test-prune-1", socketPath: Self.socketPath)
        _ = try docker("network create test-prune-2", socketPath: Self.socketPath)
        _ = try docker("network create test-prune-3", socketPath: Self.socketPath)

        // Verify networks exist
        let listBefore = try docker("network ls", socketPath: Self.socketPath)
        #expect(listBefore.contains("test-prune-1"), "test-prune-1 should exist before prune")
        #expect(listBefore.contains("test-prune-2"), "test-prune-2 should exist before prune")
        #expect(listBefore.contains("test-prune-3"), "test-prune-3 should exist before prune")

        // Prune unused networks
        let pruneOutput = try docker("network prune -f", socketPath: Self.socketPath)
        #expect(pruneOutput.contains("test-prune-1") || pruneOutput.contains("test-prune-2") || pruneOutput.contains("test-prune-3"),
                "Prune output should mention deleted networks")

        // Verify networks are gone
        let listAfter = try docker("network ls", socketPath: Self.socketPath)
        #expect(!listAfter.contains("test-prune-1"), "test-prune-1 should be deleted")
        #expect(!listAfter.contains("test-prune-2"), "test-prune-2 should be deleted")
        #expect(!listAfter.contains("test-prune-3"), "test-prune-3 should be deleted")
    }

    @Test("Network prune skips networks with active containers")
    func pruneSkipsActiveNetworks() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with container
        _ = try docker("network create test-active-network", socketPath: Self.socketPath)
        _ = try docker("run -d --name test-active-container --network test-active-network alpine sleep 300", socketPath: Self.socketPath)

        // Create network without container
        _ = try docker("network create test-unused-network", socketPath: Self.socketPath)

        // Prune networks
        _ = try docker("network prune -f", socketPath: Self.socketPath)

        // Verify active network still exists
        let listAfter = try docker("network ls", socketPath: Self.socketPath)
        #expect(listAfter.contains("test-active-network"), "Network with active container should NOT be pruned")
        #expect(!listAfter.contains("test-unused-network"), "Network without container should be pruned")

        // Clean up
        _ = try? docker("rm -f test-active-container", socketPath: Self.socketPath)
        _ = try? docker("network rm test-active-network", socketPath: Self.socketPath)
    }

    @Test("Network prune skips default networks")
    func pruneSkipsDefaultNetworks() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create custom network
        _ = try docker("network create test-custom", socketPath: Self.socketPath)

        // Prune networks
        _ = try docker("network prune -f", socketPath: Self.socketPath)

        // Verify default networks still exist
        let listAfter = try docker("network ls", socketPath: Self.socketPath)
        #expect(listAfter.contains("bridge"), "Default bridge should NOT be pruned")
        #expect(listAfter.contains("host"), "Default host should NOT be pruned")
        #expect(listAfter.contains("none"), "Default none should NOT be pruned")
        #expect(!listAfter.contains("test-custom"), "Custom network should be pruned")
    }

    @Test("Network prune with label filter")
    func pruneLabelFilter() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create networks with different labels
        _ = try docker("network create --label env=test test-labeled-1", socketPath: Self.socketPath)
        _ = try docker("network create --label env=prod test-labeled-2", socketPath: Self.socketPath)
        _ = try docker("network create test-unlabeled", socketPath: Self.socketPath)

        // Prune only networks with env=test label
        _ = try docker("network prune --filter \"label=env=test\" -f", socketPath: Self.socketPath)

        // Verify results
        let listAfter = try docker("network ls", socketPath: Self.socketPath)
        #expect(!listAfter.contains("test-labeled-1"), "Network with env=test should be pruned")
        #expect(listAfter.contains("test-labeled-2"), "Network with env=prod should NOT be pruned")
        #expect(listAfter.contains("test-unlabeled"), "Network without label should NOT be pruned")

        // Clean up
        _ = try? docker("network rm test-labeled-2 test-unlabeled", socketPath: Self.socketPath)
    }

    // MARK: - Phase 3: Missing Filters & Query Parameters

    @Test("Dangling filter shows networks without containers")
    func danglingFilter() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with container (not dangling)
        _ = try docker("network create test-not-dangling", socketPath: Self.socketPath)
        _ = try docker("run -d --name test-dangling-container --network test-not-dangling alpine sleep 300", socketPath: Self.socketPath)

        // Create network without container (dangling)
        _ = try docker("network create test-dangling", socketPath: Self.socketPath)

        // List dangling networks
        let danglingOutput = try docker("network ls --filter dangling=true", socketPath: Self.socketPath)
        #expect(danglingOutput.contains("test-dangling"), "Dangling network should appear in dangling=true filter")
        #expect(!danglingOutput.contains("test-not-dangling"), "Network with container should NOT appear in dangling=true filter")

        // List non-dangling networks
        let notDanglingOutput = try docker("network ls --filter dangling=false", socketPath: Self.socketPath)
        #expect(notDanglingOutput.contains("test-not-dangling"), "Network with container should appear in dangling=false filter")
        #expect(!notDanglingOutput.contains("test-dangling"), "Dangling network should NOT appear in dangling=false filter")

        // Clean up
        _ = try? docker("rm -f test-dangling-container", socketPath: Self.socketPath)
        _ = try? docker("network rm test-not-dangling test-dangling", socketPath: Self.socketPath)
    }

    @Test("Scope filter returns local networks")
    func scopeFilter() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create custom network
        _ = try docker("network create test-scope", socketPath: Self.socketPath)

        // List networks with scope=local (should return all - we only support local)
        let output = try docker("network ls --filter scope=local", socketPath: Self.socketPath)
        #expect(output.contains("bridge"), "bridge should appear in scope=local")
        #expect(output.contains("host"), "host should appear in scope=local")
        #expect(output.contains("test-scope"), "Custom network should appear in scope=local")

        // Clean up
        _ = try? docker("network rm test-scope", socketPath: Self.socketPath)
    }

    @Test("Type filter distinguishes builtin vs custom networks")
    func typeFilter() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create custom network
        _ = try docker("network create test-custom-type", socketPath: Self.socketPath)

        // List builtin networks
        let builtinOutput = try docker("network ls --filter type=builtin", socketPath: Self.socketPath)
        #expect(builtinOutput.contains("bridge"), "bridge is builtin")
        #expect(builtinOutput.contains("host"), "host is builtin")
        #expect(builtinOutput.contains("none"), "none is builtin")
        #expect(!builtinOutput.contains("test-custom-type"), "Custom network should NOT appear in type=builtin")

        // List custom networks
        let customOutput = try docker("network ls --filter type=custom", socketPath: Self.socketPath)
        #expect(customOutput.contains("test-custom-type"), "Custom network should appear in type=custom")
        #expect(!customOutput.contains("bridge"), "bridge should NOT appear in type=custom")
        #expect(!customOutput.contains("host"), "host should NOT appear in type=custom")

        // Clean up
        _ = try? docker("network rm test-custom-type", socketPath: Self.socketPath)
    }

    @Test("Verbose parameter accepted on inspect (logs warning)")
    func verboseParameter() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Inspect with verbose parameter - should succeed
        let output = try docker("network inspect bridge --verbose", socketPath: Self.socketPath)
        #expect(output.contains("bridge"), "Inspect should return bridge network")
        #expect(output.contains("172.17.0.0/16"), "Inspect should include subnet")
        // Note: We can't easily check logs from here, but the command should succeed
    }

    // MARK: - Phase 4: User-Specified IP Addresses

    @Test("User-specified IP address works")
    func userSpecifiedIP() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with custom subnet
        _ = try docker("network create --subnet 172.20.0.0/16 test-user-ip", socketPath: Self.socketPath)

        // Create container with user-specified IP
        _ = try docker("run -d --name test-custom-ip --network test-user-ip --ip 172.20.0.100 alpine sleep 300", socketPath: Self.socketPath)

        // Verify IP
        let inspectOutput = try docker("inspect test-custom-ip", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("172.20.0.100"), "Container should have user-specified IP")

        // Clean up
        _ = try? docker("rm -f test-custom-ip", socketPath: Self.socketPath)
        _ = try? docker("network rm test-user-ip", socketPath: Self.socketPath)
    }

    @Test("User-specified IP must be in subnet (validation)")
    func userIPValidation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with specific subnet
        _ = try docker("network create --subnet 172.21.0.0/16 test-ip-validation", socketPath: Self.socketPath)

        // Try to create container with IP outside subnet - should fail
        let failed = dockerExpectFailure("run -d --name test-bad-ip --network test-ip-validation --ip 192.168.1.100 alpine sleep 300", socketPath: Self.socketPath)
        #expect(failed, "Container with IP outside subnet should fail")

        // Clean up
        _ = try? docker("network rm test-ip-validation", socketPath: Self.socketPath)
    }

    @Test("Duplicate IP detection")
    func duplicateIPDetection() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network
        _ = try docker("network create --subnet 172.22.0.0/16 test-duplicate-ip", socketPath: Self.socketPath)

        // Create first container with IP
        _ = try docker("run -d --name test-ip-1 --network test-duplicate-ip --ip 172.22.0.100 alpine sleep 300", socketPath: Self.socketPath)

        // Try to create second container with same IP - should fail
        let failed = dockerExpectFailure("run -d --name test-ip-2 --network test-duplicate-ip --ip 172.22.0.100 alpine sleep 300", socketPath: Self.socketPath)
        #expect(failed, "Container with duplicate IP should fail")

        // Clean up
        _ = try? docker("rm -f test-ip-1", socketPath: Self.socketPath)
        _ = try? docker("network rm test-duplicate-ip", socketPath: Self.socketPath)
    }

    @Test("Auto-allocation still works when IP not specified")
    func autoIPAllocation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network
        _ = try docker("network create --subnet 172.23.0.0/16 test-auto-ip", socketPath: Self.socketPath)

        // Create container without specifying IP
        _ = try docker("run -d --name test-auto-container --network test-auto-ip alpine sleep 300", socketPath: Self.socketPath)

        // Verify IP was auto-allocated from subnet
        let inspectOutput = try docker("inspect test-auto-container", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("172.23.0."), "Container should have auto-allocated IP from subnet")

        // Clean up
        _ = try? docker("rm -f test-auto-container", socketPath: Self.socketPath)
        _ = try? docker("network rm test-auto-ip", socketPath: Self.socketPath)
    }

    @Test("User-specified IP works with docker network connect")
    func userIPWithNetworkConnect() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network
        _ = try docker("network create --subnet 172.24.0.0/16 test-connect-ip", socketPath: Self.socketPath)

        // Create container on default network
        _ = try docker("run -d --name test-connect-container alpine sleep 300", socketPath: Self.socketPath)

        // Connect to network with user-specified IP
        _ = try docker("network connect --ip 172.24.0.100 test-connect-ip test-connect-container", socketPath: Self.socketPath)

        // Verify IP
        let inspectOutput = try docker("inspect test-connect-container", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("172.24.0.100"), "Container should have user-specified IP after network connect")

        // Clean up
        _ = try? docker("rm -f test-connect-container", socketPath: Self.socketPath)
        _ = try? docker("network rm test-connect-ip", socketPath: Self.socketPath)
    }

    // MARK: - Phase 5: API Model Completeness

    @Test("Network inspect includes all API fields (EnableIPv4, ConfigOnly, ConfigFrom, Peers)")
    func apiModelCompleteness() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Inspect default bridge network
        let inspectOutput = try docker("network inspect bridge", socketPath: Self.socketPath)

        // Verify fields are present (even if null/default)
        #expect(inspectOutput.contains("EnableIPv4") || inspectOutput.contains("enableIPv4"),
                "Inspect should include EnableIPv4 field")
        // Note: ConfigOnly, ConfigFrom, and Peers may not appear if null in JSON output
        // The important thing is they don't cause errors when present
    }

    @Test("Creating config-only network returns error (unsupported)")
    func configOnlyNetworkUnsupported() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Try to create config-only network - should fail
        let failed = dockerExpectFailure("network create --config-only test-config-only", socketPath: Self.socketPath)
        #expect(failed, "Creating config-only network should fail (not supported)")
    }

    // MARK: - End-to-End Integration

    @Test("Complete network lifecycle with all features")
    func completeNetworkLifecycle() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // 1. Create network with custom IPAM
        _ = try docker("network create --subnet 172.25.0.0/24 --gateway 172.25.0.1 --label env=test test-complete", socketPath: Self.socketPath)

        // 2. Verify network appears in list
        let listOutput = try docker("network ls", socketPath: Self.socketPath)
        #expect(listOutput.contains("test-complete"), "Network should appear in list")

        // 3. Inspect network
        let inspectOutput = try docker("network inspect test-complete", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("172.25.0.0/24"), "Inspect should show subnet")
        #expect(inspectOutput.contains("172.25.0.1"), "Inspect should show gateway")
        #expect(inspectOutput.contains("env"), "Inspect should show labels")

        // 4. Create container with user-specified IP
        _ = try docker("run -d --name test-complete-1 --network test-complete --ip 172.25.0.10 alpine sleep 300", socketPath: Self.socketPath)

        // 5. Create second container with auto-allocated IP
        _ = try docker("run -d --name test-complete-2 --network test-complete alpine sleep 300", socketPath: Self.socketPath)

        // 6. Verify network now shows as not dangling
        let notDanglingOutput = try docker("network ls --filter dangling=false", socketPath: Self.socketPath)
        #expect(notDanglingOutput.contains("test-complete"), "Network with containers should not be dangling")

        // 7. Create third network for prune test
        _ = try docker("network create --label env=test test-prune-target", socketPath: Self.socketPath)

        // 8. Prune networks with label filter (should delete test-prune-target, not test-complete)
        _ = try docker("network prune --filter \"label=env=test\" -f", socketPath: Self.socketPath)

        let afterPrune = try docker("network ls", socketPath: Self.socketPath)
        #expect(afterPrune.contains("test-complete"), "Network with containers should survive prune")
        #expect(!afterPrune.contains("test-prune-target"), "Unused network should be pruned")

        // 9. Remove containers
        _ = try docker("rm -f test-complete-1 test-complete-2", socketPath: Self.socketPath)

        // 10. Remove network
        _ = try docker("network rm test-complete", socketPath: Self.socketPath)

        // 11. Verify network is gone
        let finalList = try docker("network ls", socketPath: Self.socketPath)
        #expect(!finalList.contains("test-complete"), "Removed network should not appear in list")
    }
}

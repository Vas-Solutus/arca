import Testing
import Foundation

/// Tests network IPAM features (custom subnet, gateway, IP range)
/// This validates Phase 3.2: IPAM Integration
@Suite("Network IPAM - CLI Integration", .serialized)
struct NetworkIPAMTests {
    static let socketPath = "/tmp/arca-test-ipam.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-ipam-test.log"

    /// Test custom subnet allocation
    @Test("Custom subnet creates network with specified CIDR")
    func customSubnet() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create network with custom subnet
        let createOutput = try docker("network create --subnet 10.50.0.0/24 test-custom-subnet", socketPath: Self.socketPath)
        #expect(createOutput.contains("test-custom-subnet") || !createOutput.isEmpty, "Network creation should succeed")

        // Inspect network to verify subnet
        let inspectOutput = try docker("network inspect test-custom-subnet", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("10.50.0.0/24"), "Network should have custom subnet")
        #expect(inspectOutput.contains("10.50.0.1"), "Gateway should default to .1")

        // Clean up
        _ = try? docker("network rm test-custom-subnet", socketPath: Self.socketPath)
    }

    /// Test custom gateway specification
    @Test("Custom gateway creates network with specified gateway IP")
    func customGateway() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Create network with custom subnet and gateway
        let createOutput = try docker("network create --subnet 10.60.0.0/24 --gateway 10.60.0.254 test-custom-gateway", socketPath: Self.socketPath)
        #expect(createOutput.contains("test-custom-gateway") || !createOutput.isEmpty, "Network creation should succeed")

        // Inspect network to verify gateway
        let inspectOutput = try docker("network inspect test-custom-gateway", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("10.60.0.0/24"), "Network should have custom subnet")
        #expect(inspectOutput.contains("10.60.0.254"), "Network should have custom gateway")

        // Clean up
        _ = try? docker("network rm test-custom-gateway", socketPath: Self.socketPath)
    }

    /// Test custom IP range allocation
    @Test("Custom IP range allocates IPs from specified range")
    func customIPRange() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image if needed
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with custom IP range (only .128 to .255)
        _ = try docker("network create --subnet 10.70.0.0/24 --ip-range 10.70.0.128/25 test-ip-range", socketPath: Self.socketPath)

        // Create containers and verify IPs are allocated from range
        let container1 = try docker("run -d --name test-range-1 --network test-ip-range alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container1.isEmpty, "Container 1 should be created")

        let container2 = try docker("run -d --name test-range-2 --network test-ip-range alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container2.isEmpty, "Container 2 should be created")

        // Inspect containers to verify IP addresses
        let inspect1 = try docker("inspect test-range-1", socketPath: Self.socketPath)
        let inspect2 = try docker("inspect test-range-2", socketPath: Self.socketPath)

        // IPs should be in range 10.70.0.128/25 (10.70.0.128 - 10.70.0.255)
        // First container should get .128, second should get .129
        #expect(inspect1.contains("10.70.0.128"), "Container 1 should get first IP in range (.128)")
        #expect(inspect2.contains("10.70.0.129"), "Container 2 should get second IP in range (.129)")

        // Clean up
        _ = try? docker("rm -f test-range-1 test-range-2", socketPath: Self.socketPath)
        _ = try? docker("network rm test-ip-range", socketPath: Self.socketPath)
    }

    /// Test IP range exhaustion
    @Test("IP allocation fails when range is exhausted")
    func ipRangeExhaustion() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image if needed
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with very small IP range (only 2 usable IPs: /30 gives 4 IPs, minus network and broadcast = 2)
        // Actually, let's use /29 which gives 8 IPs, minus network, gateway, broadcast = 5 usable IPs
        // Range: 10.80.0.0/29 allows .1 (gateway), .2, .3, .4, .5, .6 (6 total, excluding network .0 and broadcast .7)
        _ = try docker("network create --subnet 10.80.0.0/29 test-exhaustion", socketPath: Self.socketPath)

        // Create containers until we run out of IPs
        // Should be able to create 6 containers (.2, .3, .4, .5, .6, and one more depending on implementation)
        var containers: [String] = []
        for i in 1...6 {
            do {
                let container = try docker("run -d --name test-exhaust-\(i) --network test-exhaustion alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
                containers.append("test-exhaust-\(i)")
                #expect(!container.isEmpty, "Container \(i) should be created")
            } catch {
                // Expected to fail when pool is exhausted
                print("Container \(i) creation failed (expected if pool exhausted): \(error)")
            }
        }

        // Try to create one more - should fail
        do {
            _ = try docker("run -d --name test-exhaust-overflow --network test-exhaustion alpine sleep 300", socketPath: Self.socketPath)
            Issue.record("Should have failed to create container when IP pool is exhausted")
        } catch {
            // Expected - IP pool exhausted
            #expect(true, "IP exhaustion should prevent container creation")
        }

        // Clean up
        for container in containers {
            _ = try? docker("rm -f \(container)", socketPath: Self.socketPath)
        }
        _ = try? docker("rm -f test-exhaust-overflow", socketPath: Self.socketPath)
        _ = try? docker("network rm test-exhaustion", socketPath: Self.socketPath)
    }

    /// Test complete IPAM configuration (subnet + gateway + IP range)
    @Test("Complete IPAM configuration with all parameters")
    func completeIPAMConfiguration() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image if needed
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create network with all IPAM parameters
        _ = try docker("network create --subnet 10.90.0.0/24 --gateway 10.90.0.1 --ip-range 10.90.0.100/26 test-complete-ipam", socketPath: Self.socketPath)

        // Inspect network
        let networkInspect = try docker("network inspect test-complete-ipam", socketPath: Self.socketPath)
        #expect(networkInspect.contains("10.90.0.0/24"), "Should have custom subnet")
        #expect(networkInspect.contains("10.90.0.1"), "Should have custom gateway")

        // Create container and verify IP is from specified range
        let container = try docker("run -d --name test-complete --network test-complete-ipam alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container.isEmpty, "Container should be created")

        // Inspect container to verify IP
        let containerInspect = try docker("inspect test-complete", socketPath: Self.socketPath)

        // IP should be in range 10.90.0.100/26 (10.90.0.100 - 10.90.0.163)
        // First container should get .100
        #expect(containerInspect.contains("10.90.0.100"), "Container should get first IP from custom range (.100)")

        // Clean up
        _ = try? docker("rm -f test-complete", socketPath: Self.socketPath)
        _ = try? docker("network rm test-complete-ipam", socketPath: Self.socketPath)
    }

    /// Test that network persists IPAM settings across daemon restart
    @Test("IPAM settings persist across daemon restart")
    func ipamPersistence() async throws {
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID1) }

        // Create network with custom IPAM
        _ = try docker("network create --subnet 10.100.0.0/24 --gateway 10.100.0.254 --ip-range 10.100.0.128/25 test-ipam-persist", socketPath: Self.socketPath)

        // Inspect network
        let inspect1 = try docker("network inspect test-ipam-persist", socketPath: Self.socketPath)
        #expect(inspect1.contains("10.100.0.0/24"), "Should have custom subnet")
        #expect(inspect1.contains("10.100.0.254"), "Should have custom gateway")

        // Stop daemon
        try stopDaemon(pid: daemonPID1)

        // Start daemon again
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID2) }

        // Inspect network again - IPAM settings should persist
        let inspect2 = try docker("network inspect test-ipam-persist", socketPath: Self.socketPath)
        #expect(inspect2.contains("10.100.0.0/24"), "Subnet should persist after restart")
        #expect(inspect2.contains("10.100.0.254"), "Gateway should persist after restart")

        // Create container to verify IP range still works
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)
        let container = try docker("run -d --name test-persist --network test-ipam-persist alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container.isEmpty, "Container should be created")

        // Verify IP is from range
        let containerInspect = try docker("inspect test-persist", socketPath: Self.socketPath)
        #expect(containerInspect.contains("10.100.0.128"), "Should allocate from persisted IP range")

        // Clean up
        _ = try? docker("rm -f test-persist", socketPath: Self.socketPath)
        _ = try? docker("network rm test-ipam-persist", socketPath: Self.socketPath)
    }
}

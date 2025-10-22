import Foundation
import ContainerBridge
import Logging

/// ArcaTestHelper - Signed test binary for helper VM integration tests
///
/// This binary has the same entitlements as the Arca daemon, allowing it to
/// create and manage VMs for testing purposes.

let logger = Logger(label: "arca.test-helper")

print("=== Arca Helper VM Integration Test ===\n")

// Test execution
do {
    // Load configuration
    print("1. Loading configuration...")
    let configManager = ConfigManager(logger: logger)
    let config = try configManager.loadConfig()
    print("   ✓ Config loaded: kernel=\(config.kernelPath)")

    // Initialize ImageManager
    print("\n2. Initializing ImageManager...")
    let imageManager = try ImageManager(logger: logger)
    try await imageManager.initialize()
    print("   ✓ ImageManager initialized")

    // Initialize NetworkHelperVM
    print("\n3. Initializing NetworkHelperVM...")
    let helperVM = NetworkHelperVM(
        imageManager: imageManager,
        kernelPath: config.kernelPath,
        logger: logger
    )
    try await helperVM.initialize()
    print("   ✓ NetworkHelperVM initialized")

    // Start the helper VM
    print("\n4. Starting helper VM (this takes ~15 seconds)...")
    try await helperVM.start()
    print("   ✓ Helper VM started")

    // Get OVN client
    print("\n5. Getting OVN client...")
    guard let ovnClient = await helperVM.getOVNClient() else {
        print("   ✗ FAILED: OVN client not available")
        exit(1)
    }
    print("   ✓ OVN client connected via vsock")

    // Test 1: Health check
    print("\n6. Testing health check...")
    let health = try await ovnClient.getHealth()
    print("   Health Status:")
    print("     - Healthy: \(health.healthy)")
    print("     - OVS: \(health.ovsStatus)")
    print("     - OVN: \(health.ovnStatus)")
    print("     - Dnsmasq: \(health.dnsmasqStatus)")
    print("     - Uptime: \(health.uptimeSeconds)s")

    if !health.healthy {
        print("   ✗ FAILED: Helper VM not healthy")
        exit(1)
    }
    if health.ovsStatus != "running" {
        print("   ✗ FAILED: OVS not running")
        exit(1)
    }
    if health.ovnStatus != "running" {
        print("   ✗ FAILED: OVN not running")
        exit(1)
    }
    print("   ✓ Health check passed")

    // Test 2: Create bridge
    print("\n7. Testing bridge creation...")
    let networkID = "test-network-\(UUID().uuidString.prefix(8))"
    let subnet = "172.20.0.0/16"
    let gateway = "172.20.0.1"

    let bridgeName = try await ovnClient.createBridge(
        networkID: networkID,
        subnet: subnet,
        gateway: gateway
    )
    print("   ✓ Bridge created: \(bridgeName)")

    if !bridgeName.hasPrefix("br-") {
        print("   ✗ FAILED: Bridge name doesn't match expected pattern (expected 'br-*')")
        exit(1)
    }

    // Test 3: List bridges
    print("\n8. Testing bridge listing...")
    var bridges = try await ovnClient.listBridges()
    print("   Found \(bridges.count) bridge(s)")

    let foundBridge = bridges.first { $0.networkID == networkID }
    guard let bridge = foundBridge else {
        print("   ✗ FAILED: Created bridge not found in list")
        exit(1)
    }

    print("   Bridge details:")
    print("     - Network ID: \(bridge.networkID)")
    print("     - Bridge Name: \(bridge.bridgeName)")
    print("     - Subnet: \(bridge.subnet)")
    print("     - Gateway: \(bridge.gateway)")

    if bridge.subnet != subnet {
        print("   ✗ FAILED: Subnet mismatch (expected: \(subnet), got: \(bridge.subnet))")
        exit(1)
    }
    if bridge.gateway != gateway {
        print("   ✗ FAILED: Gateway mismatch (expected: \(gateway), got: \(bridge.gateway))")
        exit(1)
    }
    print("   ✓ Bridge listing passed")

    // Test 4: Create additional bridges
    print("\n9. Testing multiple bridge creation...")
    var additionalNetworks: [(id: String, subnet: String, gateway: String)] = []

    for i in 1...2 {
        let netID = "test-multi-\(i)-\(UUID().uuidString.prefix(6))"
        let netSubnet = "172.\(20 + i).0.0/16"
        let netGateway = "172.\(20 + i).0.1"

        let netBridge = try await ovnClient.createBridge(
            networkID: netID,
            subnet: netSubnet,
            gateway: netGateway
        )
        additionalNetworks.append((netID, netSubnet, netGateway))
        print("   ✓ Created bridge \(i): \(netBridge)")

        // Small delay to avoid TAP device "Resource busy" errors in rapid succession
        if i < 2 {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
    }

    // Verify all bridges exist
    bridges = try await ovnClient.listBridges()
    print("   Total bridges: \(bridges.count)")

    for network in additionalNetworks {
        if bridges.first(where: { $0.networkID == network.id }) == nil {
            print("   ✗ FAILED: Bridge \(network.id) not found")
            exit(1)
        }
    }
    print("   ✓ Multiple bridge creation passed")

    // Test 5: Delete bridge
    print("\n10. Testing bridge deletion...")
    try await ovnClient.deleteBridge(networkID: networkID)
    print("   ✓ Bridge deleted: \(networkID)")

    // Verify it's gone
    bridges = try await ovnClient.listBridges()
    if bridges.first(where: { $0.networkID == networkID }) != nil {
        print("   ✗ FAILED: Bridge still exists after deletion")
        exit(1)
    }
    print("   ✓ Bridge deletion verified")

    // Test 6: Delete additional bridges
    print("\n11. Cleaning up additional bridges...")
    for network in additionalNetworks {
        try await ovnClient.deleteBridge(networkID: network.id)
        print("   ✓ Deleted: \(network.id)")
    }

    // Verify all deleted
    bridges = try await ovnClient.listBridges()
    for network in additionalNetworks {
        if bridges.first(where: { $0.networkID == network.id }) != nil {
            print("   ✗ FAILED: Bridge \(network.id) still exists after deletion")
            exit(1)
        }
    }
    print("   ✓ All bridges cleaned up")

    // Test 7: Test OVN database operations
    print("\n12. Testing OVN database operations...")
    let dbTestNetwork = "test-db-\(UUID().uuidString.prefix(8))"
    let dbBridge = try await ovnClient.createBridge(
        networkID: dbTestNetwork,
        subnet: "172.30.0.0/16",
        gateway: "172.30.0.1"
    )
    print("   ✓ Created test bridge: \(dbBridge)")

    // List to query database
    bridges = try await ovnClient.listBridges()
    if bridges.first(where: { $0.networkID == dbTestNetwork }) == nil {
        print("   ✗ FAILED: Database query failed")
        exit(1)
    }
    print("   ✓ Database query successful")

    // Clean up
    try await ovnClient.deleteBridge(networkID: dbTestNetwork)
    print("   ✓ Test bridge cleaned up")

    // Stop helper VM
    print("\n13. Stopping helper VM...")
    try await helperVM.stop()
    print("   ✓ Helper VM stopped")

    // Success!
    print("\n" + String(repeating: "=", count: 50))
    print("✅ ALL TESTS PASSED!")
    print(String(repeating: "=", count: 50))

    exit(0)

} catch {
    print("\n❌ TEST FAILED WITH ERROR:")
    print("   \(error)")
    print("\nStack trace:")
    print(Thread.callStackSymbols.joined(separator: "\n"))
    exit(1)
}

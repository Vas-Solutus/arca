import Testing
@testable import ContainerBridge
@testable import ArcaDaemon
import Logging
import Foundation

/// Integration tests for NetworkHelperVM
///
/// These tests verify the helper VM functionality by:
/// 1. Loading the helper VM OCI image from ~/.arca/helpervm/oci-layout
/// 2. Starting the helper VM as a Container managed by Containerization framework
/// 3. Connecting to it via Container.dial() over vsock
/// 4. Testing gRPC operations (health check, bridge creation, etc.)
///
/// Prerequisites:
/// - Helper VM image built: `make helpervm`
/// - This creates OCI layout at ~/.arca/helpervm/oci-layout/
struct NetworkHelperVMTests {

    private let logger = Logger(label: "arca.tests.helpervm")

    /// Helper to check if prerequisites are met
    private func checkPrerequisites() throws {
        // Check for OCI layout
        let ociLayoutPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm")
            .appendingPathComponent("oci-layout")

        guard FileManager.default.fileExists(atPath: ociLayoutPath.path) else {
            throw SkipTestError("""
                Helper VM OCI layout not found at \(ociLayoutPath.path)

                Build the helper VM first:
                  make helpervm
                """)
        }

        // Check for kernel
        let kernelPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("vmlinux")

        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw SkipTestError("""
                Linux kernel not found at \(kernelPath.path)

                The helper VM requires a Linux kernel to run.
                """)
        }
    }

    @Test("Helper VM OCI layout exists and is valid")
    func helperVMImageExists() throws {
        try checkPrerequisites()

        let ociLayoutPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm")
            .appendingPathComponent("oci-layout")

        // Check for oci-layout file
        let layoutFile = ociLayoutPath.appendingPathComponent("oci-layout")
        #expect(FileManager.default.fileExists(atPath: layoutFile.path),
                "oci-layout file should exist at \(layoutFile.path)")

        // Check for index.json
        let indexFile = ociLayoutPath.appendingPathComponent("index.json")
        #expect(FileManager.default.fileExists(atPath: indexFile.path),
                "index.json file should exist at \(indexFile.path)")

        // Check for blobs directory
        let blobsDir = ociLayoutPath.appendingPathComponent("blobs")
        var isDir: ObjCBool = false
        let blobsExist = FileManager.default.fileExists(atPath: blobsDir.path, isDirectory: &isDir)
        #expect(blobsExist && isDir.boolValue,
                "blobs directory should exist at \(blobsDir.path)")
    }

    @Test("NetworkHelperVM can be initialized", .timeLimit(.minutes(1)))
    func initializeHelperVM() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        // Initialize should complete without errors
        try await helperVM.initialize()

        print("✓ NetworkHelperVM initialized successfully")
    }

    @Test("Helper VM can be started and stopped", .timeLimit(.minutes(1)))
    func startStopHelperVM() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        // Initialize
        try await helperVM.initialize()
        print("✓ Helper VM initialized")

        // Start the helper VM
        print("Starting helper VM (this may take 10-15 seconds)...")
        try await helperVM.start()
        print("✓ Helper VM started")

        // Give it a moment to fully initialize
        try await Task.sleep(for: .seconds(2))

        // Stop the helper VM
        print("Stopping helper VM...")
        try await helperVM.stop()
        print("✓ Helper VM stopped")
    }

    @Test("Helper VM health check via vsock", .timeLimit(.minutes(1)))
    func helperVMHealthCheck() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM for health check...")
            try await helperVM.start()

            // The start() method now automatically connects the OVN client via vsock
            // Check if we can get the OVN client
            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client not available after helper VM start")
            }

            print("✓ OVN client connected via vsock")

            // Perform health check
            print("Performing health check...")
            let health = try await ovnClient.getHealth()

            print("Health check results:")
            print("  Healthy: \(health.healthy)")
            print("  OVS Status: \(health.ovsStatus)")
            print("  OVN Status: \(health.ovnStatus)")
            print("  Dnsmasq Status: \(health.dnsmasqStatus)")
            print("  Uptime: \(health.uptimeSeconds)s")

            #expect(health.healthy, "Helper VM should report healthy status")
            #expect(health.ovsStatus == "running", "OVS should be running")
            #expect(health.ovnStatus == "running", "OVN should be running")

            // Also test the isHealthy() convenience method
            let isHealthy = await helperVM.isHealthy()
            #expect(isHealthy, "Helper VM should be healthy")

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            // Ensure cleanup even on failure
            try? await helperVM.stop()
            throw error
        }
    }

    @Test("Can create OVN bridge via gRPC", .timeLimit(.minutes(1)))
    func createBridge() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM for bridge creation test...")
            try await helperVM.start()

            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client not available")
            }

            // Create a test bridge
            let networkID = "test-network-\(UUID().uuidString.prefix(8))"
            print("Creating bridge for network: \(networkID)")

            let bridgeName = try await ovnClient.createBridge(
                networkID: networkID,
                subnet: "172.20.0.0/16",
                gateway: "172.20.0.1"
            )

            print("✓ Bridge created: \(bridgeName)")
            #expect(bridgeName.contains("arca-br"), "Bridge name should contain 'arca-br'")

            // List bridges to verify creation
            let bridges = try await ovnClient.listBridges()
            print("Found \(bridges.count) bridge(s)")

            let foundBridge = bridges.first { $0.networkID == networkID }
            #expect(foundBridge != nil, "Created bridge should appear in list")

            if let bridge = foundBridge {
                print("  Network ID: \(bridge.networkID)")
                print("  Bridge Name: \(bridge.bridgeName)")
                print("  Subnet: \(bridge.subnet)")
                print("  Gateway: \(bridge.gateway)")
                #expect(bridge.subnet == "172.20.0.0/16", "Subnet should match")
                #expect(bridge.gateway == "172.20.0.1", "Gateway should match")
            }

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            try? await helperVM.stop()
            throw error
        }
    }

    @Test("Can delete OVN bridge via gRPC", .timeLimit(.minutes(1)))
    func deleteBridge() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM for bridge deletion test...")
            try await helperVM.start()

            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client not available")
            }

            // Create a test bridge
            let networkID = "test-delete-\(UUID().uuidString.prefix(8))"
            print("Creating bridge for network: \(networkID)")

            let bridgeName = try await ovnClient.createBridge(
                networkID: networkID,
                subnet: "172.21.0.0/16",
                gateway: "172.21.0.1"
            )
            print("✓ Bridge created: \(bridgeName)")

            // Verify it exists
            var bridges = try await ovnClient.listBridges()
            var foundBridge = bridges.first { $0.networkID == networkID }
            #expect(foundBridge != nil, "Bridge should exist before deletion")

            // Delete the bridge
            print("Deleting bridge for network: \(networkID)")
            try await ovnClient.deleteBridge(networkID: networkID)
            print("✓ Bridge deleted")

            // Verify it's gone
            bridges = try await ovnClient.listBridges()
            foundBridge = bridges.first { $0.networkID == networkID }
            #expect(foundBridge == nil, "Bridge should not exist after deletion")

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            try? await helperVM.stop()
            throw error
        }
    }

    @Test("Container.dial() vsock connectivity", .timeLimit(.minutes(1)))
    func vsockConnectivity() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM for vsock connectivity test...")
            try await helperVM.start()

            // The helper VM automatically connects the OVN client via Container.dial()
            // Verify we got a client
            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client should be connected after start()")
            }

            print("✓ OVN client connected via Container.dial() over vsock")

            // Verify we can actually communicate
            let health = try await ovnClient.getHealth()
            #expect(health.healthy, "Should be able to communicate over vsock connection")

            print("✓ vsock communication successful")
            print("  Protocol: gRPC over vsock (port 9999)")
            print("  Method: Container.dialVsock()")
            print("  Health: \(health.healthy)")

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            try? await helperVM.stop()
            throw error
        }
    }

    @Test("OVN databases are initialized correctly", .timeLimit(.minutes(1)))
    func ovnDatabasesInitialized() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM to verify OVN database initialization...")
            try await helperVM.start()

            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client not available")
            }

            // Get health to check database status
            let health = try await ovnClient.getHealth()

            print("OVN Database Status:")
            print("  OVN Northbound: \(health.ovnStatus)")
            print("  OVN Southbound: \(health.ovnStatus)")
            print("  OVN Controller: \(health.ovnStatus)")

            #expect(health.ovnStatus == "running", "OVN databases should be running")

            // Try to create a bridge - this requires working databases
            let networkID = "test-db-\(UUID().uuidString.prefix(8))"
            print("Creating test bridge to verify database operations...")

            let bridgeName = try await ovnClient.createBridge(
                networkID: networkID,
                subnet: "172.22.0.0/16",
                gateway: "172.22.0.1"
            )

            print("✓ Bridge created successfully: \(bridgeName)")
            print("  This confirms OVN northbound and southbound databases are working")

            // List bridges - this queries the databases
            let bridges = try await ovnClient.listBridges()
            #expect(bridges.count > 0, "Should be able to list bridges from database")

            print("✓ Successfully queried OVN databases")
            print("  Found \(bridges.count) bridge(s)")

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            try? await helperVM.stop()
            throw error
        }
    }

    @Test("Multiple bridge operations in sequence", .timeLimit(.minutes(2)))
    func multipleBridgeOperations() async throws {
        try checkPrerequisites()

        let config = try ContainerBridge.ConfigManager(logger: logger).loadConfig()
        let imageManager = try ImageManager(logger: logger)
        try await imageManager.initialize()

        let helperVM = NetworkHelperVM(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
        )

        do {
            // Initialize and start
            try await helperVM.initialize()
            print("Starting helper VM for multiple bridge operations test...")
            try await helperVM.start()

            guard let ovnClient = await helperVM.getOVNClient() else {
                throw TestError("OVN client not available")
            }

            // Create multiple bridges
            var networkIDs: [String] = []
            for i in 1...3 {
                let networkID = "test-multi-\(i)-\(UUID().uuidString.prefix(6))"
                networkIDs.append(networkID)

                let subnet = "172.\(20 + i).0.0/16"
                let gateway = "172.\(20 + i).0.1"

                print("Creating bridge \(i)/3: \(networkID)")
                let bridgeName = try await ovnClient.createBridge(
                    networkID: networkID,
                    subnet: subnet,
                    gateway: gateway
                )
                print("  ✓ Created: \(bridgeName)")
            }

            // List all bridges
            let bridges = try await ovnClient.listBridges()
            print("\nTotal bridges: \(bridges.count)")
            #expect(bridges.count >= 3, "Should have at least 3 bridges")

            // Verify all our bridges exist
            for networkID in networkIDs {
                let found = bridges.first { $0.networkID == networkID }
                #expect(found != nil, "Bridge \(networkID) should exist")
            }

            // Delete bridges in reverse order
            for (i, networkID) in networkIDs.reversed().enumerated() {
                print("Deleting bridge \(i + 1)/3: \(networkID)")
                try await ovnClient.deleteBridge(networkID: networkID)
                print("  ✓ Deleted")
            }

            // Verify all deleted
            let finalBridges = try await ovnClient.listBridges()
            for networkID in networkIDs {
                let found = finalBridges.first { $0.networkID == networkID }
                #expect(found == nil, "Bridge \(networkID) should be deleted")
            }

            print("✓ All bridge operations completed successfully")

            // Clean up
            try await helperVM.stop()
            print("✓ Helper VM stopped successfully")

        } catch {
            try? await helperVM.stop()
            throw error
        }
    }
}

// MARK: - Test Errors

/// Error thrown during tests
struct TestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

/// Error thrown to skip a test
struct SkipTestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

import Foundation
import Logging
import Containerization

/// Manages Docker networks with configurable backend:
/// - OVS backend (default): Full Docker compatibility with OVS/OVN helper VM
/// - vmnet backend: High performance native vmnet (limited features)
///
/// NetworkManager acts as a facade that delegates to the appropriate backend
/// based on user configuration and network driver type.
public actor NetworkManager {
    private let config: ArcaConfig
    private let logger: Logger
    private let stateStore: StateStore
    private let containerManager: ContainerManager

    // Backends (initialized based on config)
    private var ovsBackend: OVSNetworkBackend?
    private var vmnetBackend: VmnetNetworkBackend?
    private var wireGuardBackend: WireGuardNetworkBackend?

    // Central network routing: networkID -> driver
    // This avoids "try all backends" pattern and provides O(1) backend lookup
    private var networkDrivers: [String: String] = [:]
    private var networkNames: [String: String] = [:]  // name -> ID mapping

    // Control plane for OVS backend
    private var controlPlaneContainer: Containerization.LinuxContainer?
    private var ovnClient: OVNClient?

    // Dependencies for OVS backend
    private let networkBridge: NetworkBridge?

    /// Initialize NetworkManager with configuration
    public init(
        config: ArcaConfig,
        stateStore: StateStore,
        containerManager: ContainerManager,
        networkBridge: NetworkBridge?,
        logger: Logger
    ) {
        self.config = config
        self.stateStore = stateStore
        self.containerManager = containerManager
        self.networkBridge = networkBridge
        self.logger = logger
    }

    /// Initialize the network manager and backends
    public func initialize() async throws {
        logger.info("Initializing NetworkManager", metadata: [
            "backend": "\(config.networkBackend.rawValue)"
        ])

        switch config.networkBackend {
        case .ovs:
            // Initialize OVS backend (requires control plane container)
            guard let networkBridge = networkBridge else {
                throw NetworkManagerError.helperVMNotReady
            }

            // Create or get control plane container
            try await ensureControlPlane()

            // Create OVN client
            guard let container = controlPlaneContainer else {
                throw NetworkManagerError.helperVMNotReady
            }

            let client = OVNClient(logger: logger)

            // Retry connection with exponential backoff
            // Control plane needs time to initialize OVS/OVN services before accepting connections
            let maxAttempts = 10
            var attempt = 0
            var lastError: Error?

            while attempt < maxAttempts {
                attempt += 1

                do {
                    logger.info("Attempting to connect to control plane", metadata: [
                        "attempt": "\(attempt)/\(maxAttempts)"
                    ])
                    try await client.connect(container: container, vsockPort: 9999)
                    self.ovnClient = client
                    logger.info("OVN client connected to control plane", metadata: [
                        "attempts": "\(attempt)"
                    ])
                    break
                } catch {
                    lastError = error
                    logger.warning("Connection attempt failed", metadata: [
                        "attempt": "\(attempt)/\(maxAttempts)",
                        "error": "\(error)"
                    ])

                    if attempt < maxAttempts {
                        // Exponential backoff: 0.5s, 1s, 2s, 4s, 8s, 16s, 16s, 16s, 16s
                        let backoffSeconds = min(0.5 * Double(1 << (attempt - 1)), 16.0)
                        logger.debug("Retrying in \(backoffSeconds)s...")
                        try await Task.sleep(for: .seconds(backoffSeconds))
                    }
                }
            }

            // If all attempts failed, throw the last error
            if self.ovnClient == nil {
                logger.error("Failed to connect to control plane after \(maxAttempts) attempts")
                throw lastError ?? NetworkManagerError.helperVMNotReady
            }

            let backend = OVSNetworkBackend(
                stateStore: stateStore,
                ovnClient: client,
                networkBridge: networkBridge,
                logger: logger
            )
            try await backend.initialize()
            self.ovsBackend = backend

            logger.info("OVS backend initialized")

        case .vmnet:
            // Initialize vmnet backend (no dependencies)
            let backend = VmnetNetworkBackend(logger: logger)
            self.vmnetBackend = backend

            logger.info("vmnet backend initialized")

        case .wireguard:
            // Initialize WireGuard backend (no dependencies)
            let backend = WireGuardNetworkBackend(logger: logger)
            self.wireGuardBackend = backend

            logger.info("WireGuard backend initialized")
        }

        // Load network driver and name mappings from StateStore
        // This allows us to route network operations to the correct backend efficiently
        do {
            let persistedNetworks = try await stateStore.loadAllNetworks()
            for network in persistedNetworks {
                networkDrivers[network.id] = network.driver
                networkNames[network.name] = network.id
            }
            logger.info("Loaded network mappings", metadata: ["count": "\(networkDrivers.count)"])
        } catch {
            logger.error("Failed to load network mappings", metadata: ["error": "\(error)"])
            // Continue - backends will still work, just without persisted mappings
        }

        logger.info("NetworkManager initialized successfully")
    }

    /// Ensure control plane container exists and is running
    private func ensureControlPlane() async throws {
        logger.info("Ensuring control plane container exists and is running")

        // Check if control plane already exists
        if let existingID = await containerManager.resolveContainer(idOrName: "arca-control-plane") {
            logger.info("Control plane container already exists", metadata: ["id": "\(existingID)"])

            // Get the container object
            let container = try? await containerManager.getLinuxContainer(dockerID: existingID)
            if let container = container {
                self.controlPlaneContainer = container
                logger.info("Control plane container retrieved")

                // Set control plane on network bridge
                if let bridge = networkBridge {
                    await bridge.setControlPlane(container)
                    logger.info("Network bridge configured with control plane container")
                }

                // Check if it's running
                if let info = try? await containerManager.getContainer(id: existingID) {
                    if info.state.status == "running" {
                        logger.info("Control plane container is already running")
                        return
                    }
                }

                // Start it if it's not running
                logger.info("Starting control plane container")
                try await containerManager.startContainer(id: existingID)
                logger.info("Control plane container started")
                return
            }
        }

        // Create control plane container
        logger.info("Creating control plane container")

        // Create volume directory for OVN data
        let volumePath = NSString(string: "~/.arca/control-plane/ovn-data").expandingTildeInPath
        try FileManager.default.createDirectory(atPath: volumePath, withIntermediateDirectories: true)

        let dockerID = try await containerManager.createContainer(
            image: "arca-control-plane:latest",
            name: "arca-control-plane",
            entrypoint: nil,  // Use image default entrypoint (["/usr/local/bin/startup.sh"])
            command: nil,  // Use image default cmd (empty)
            env: nil,
            workingDir: nil,
            labels: [
                "com.arca.internal": "true",
                "com.arca.role": "control-plane",
                "com.arca.skip-embedded-dns": "true"  // vmnet containers use gateway DNS, not embedded-DNS
            ],
            attachStdin: false,
            attachStdout: false,
            attachStderr: false,
            tty: false,
            openStdin: false,
            networkMode: "vmnet",  // Use Apple NATInterface for internet access
            restartPolicy: RestartPolicy(name: "always", maximumRetryCount: 0),
            binds: ["\(volumePath):/etc/ovn"]
        )

        logger.info("Control plane container created", metadata: ["id": "\(dockerID)"])

        // Start the container
        try await containerManager.startContainer(id: dockerID)
        logger.info("Control plane container started")

        // Get the container object
        guard let container = try? await containerManager.getLinuxContainer(dockerID: dockerID) else {
            throw NetworkManagerError.helperVMNotReady
        }
        self.controlPlaneContainer = container

        // Set control plane on network bridge
        if let bridge = networkBridge {
            await bridge.setControlPlane(container)
            logger.info("Network bridge configured with control plane container")
        }
    }

    // MARK: - Network CRUD Operations

    /// Create a new network
    public func createNetwork(
        name: String,
        driver: String?,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) async throws -> String {
        // Determine effective driver (explicit driver or default backend)
        let effectiveDriver = driver ?? config.networkBackend.rawValue

        // Generate network ID
        let networkID = generateNetworkID()

        logger.info("Creating network", metadata: [
            "name": "\(name)",
            "driver": "\(effectiveDriver)",
            "network_id": "\(networkID)"
        ])

        // Validate network name
        guard !name.isEmpty else {
            throw NetworkManagerError.invalidName("Network name cannot be empty")
        }

        // Route to appropriate backend
        switch effectiveDriver {
        case "bridge":
            // Use configured default backend for bridge networks
            return try await createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels,
                isDefault: isDefault
            )

        case "vmnet":
            // Explicitly requested vmnet driver
            if vmnetBackend == nil {
                // If vmnet backend not initialized, create it on-demand
                let backend = VmnetNetworkBackend(logger: logger)
                self.vmnetBackend = backend
            }

            let metadata = try await vmnetBackend!.createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels
            )

            // Register in mappings
            networkDrivers[networkID] = metadata.driver
            networkNames[name] = networkID

            return metadata.id

        case "overlay":
            // Overlay networks always use OVS/OVN
            guard let backend = ovsBackend else {
                throw NetworkManagerError.unsupportedDriver("overlay (requires OVS backend)")
            }

            let metadata = try await backend.createOverlayNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels
            )

            // Register in mappings
            networkDrivers[networkID] = metadata.driver
            networkNames[name] = networkID

            return metadata.id

        case "wireguard":
            // Explicitly requested WireGuard driver
            if wireGuardBackend == nil {
                // If WireGuard backend not initialized, create it on-demand
                let backend = WireGuardNetworkBackend(logger: logger)
                self.wireGuardBackend = backend
            }

            let metadata = try await wireGuardBackend!.createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels
            )

            // Register in mappings
            networkDrivers[networkID] = metadata.driver
            networkNames[name] = networkID

            return metadata.id

        default:
            throw NetworkManagerError.unsupportedDriver(effectiveDriver)
        }
    }

    /// Create a bridge network using the configured default backend
    private func createBridgeNetwork(
        id: String,
        name: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool
    ) async throws -> String {
        let driver: String

        switch config.networkBackend {
        case .ovs:
            guard let backend = ovsBackend else {
                throw NetworkManagerError.helperVMNotReady
            }

            let metadata = try await backend.createBridgeNetwork(
                id: id,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels,
                isDefault: isDefault
            )
            driver = metadata.driver

        case .vmnet:
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.helperVMNotReady
            }

            let metadata = try await backend.createBridgeNetwork(
                id: id,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels
            )
            driver = metadata.driver

        case .wireguard:
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.helperVMNotReady
            }

            let metadata = try await backend.createBridgeNetwork(
                id: id,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels
            )
            driver = metadata.driver
        }

        // Register network driver and name mappings for efficient routing
        networkDrivers[id] = driver
        networkNames[name] = id

        return id
    }

    /// Delete a network
    public func deleteNetwork(id: String) async throws {
        // Look up driver from central mapping
        guard let driver = networkDrivers[id] else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Get network name for cleanup (do this before deletion)
        let networkName = await getNetwork(id: id)?.name

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge":
            // Bridge networks use the configured default backend
            switch config.networkBackend {
            case .ovs:
                guard let backend = ovsBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.deleteNetwork(id: id)

            case .vmnet:
                guard let backend = vmnetBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.deleteBridgeNetwork(id: id)

            case .wireguard:
                guard let backend = wireGuardBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.deleteBridgeNetwork(id: id)
            }

        case "vmnet":
            // Explicitly requested vmnet driver
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "wireguard":
            // Explicitly requested WireGuard driver
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.unsupportedDriver("wireguard (backend not initialized)")
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "overlay":
            // Overlay networks always use OVS/OVN
            guard let backend = ovsBackend else {
                throw NetworkManagerError.unsupportedDriver("overlay (requires OVS backend)")
            }
            try await backend.deleteNetwork(id: id)

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }

        // Remove from mappings after successful deletion
        networkDrivers.removeValue(forKey: id)
        if let name = networkName {
            networkNames.removeValue(forKey: name)
        }
    }

    // MARK: - Container Attachment

    /// Attach container to network
    public func attachContainerToNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String] = []
    ) async throws -> NetworkAttachment {
        // Look up driver from central mapping
        guard let driver = networkDrivers[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge":
            // Bridge networks route based on configured backend
            switch config.networkBackend {
            case .ovs:
                guard let backend = ovsBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                return try await backend.attachContainer(
                    containerID: containerID,
                    container: container,
                    networkID: networkID,
                    containerName: containerName,
                    aliases: aliases
                )

            case .vmnet:
                guard let backend = vmnetBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                // vmnet backend doesn't support dynamic attach
                try await backend.attachContainer(
                    containerID: containerID,
                    networkID: networkID,
                    ipAddress: "",  // Not used (will throw error)
                    gateway: ""     // Not used (will throw error)
                )
                fatalError("vmnet backend should have thrown dynamicAttachNotSupported")

            case .wireguard:
                guard let backend = wireGuardBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                return try await backend.attachContainer(
                    containerID: containerID,
                    container: container,
                    networkID: networkID,
                    containerName: containerName,
                    aliases: aliases
                )
            }

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.attachContainer(
                containerID: containerID,
                networkID: networkID,
                ipAddress: "",
                gateway: ""
            )
            fatalError("vmnet backend should have thrown dynamicAttachNotSupported")

        case "wireguard":
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.unsupportedDriver("wireguard (backend not initialized)")
            }
            return try await backend.attachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID,
                containerName: containerName,
                aliases: aliases
            )

        case "overlay":
            guard let backend = ovsBackend else {
                throw NetworkManagerError.unsupportedDriver("overlay (requires OVS backend)")
            }
            return try await backend.attachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID,
                containerName: containerName,
                aliases: aliases
            )

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }
    }

    /// Detach container from network
    public func detachContainerFromNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        // Look up driver from central mapping
        guard let driver = networkDrivers[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge":
            // Bridge networks route based on configured backend
            switch config.networkBackend {
            case .ovs:
                guard let backend = ovsBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.detachContainer(
                    containerID: containerID,
                    container: container,
                    networkID: networkID
                )

            case .vmnet:
                guard let backend = vmnetBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.detachContainer(containerID: containerID, networkID: networkID)

            case .wireguard:
                guard let backend = wireGuardBackend else {
                    throw NetworkManagerError.helperVMNotReady
                }
                try await backend.detachContainer(
                    containerID: containerID,
                    container: container,
                    networkID: networkID
                )
            }

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.detachContainer(containerID: containerID, networkID: networkID)

        case "wireguard":
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.unsupportedDriver("wireguard (backend not initialized)")
            }
            try await backend.detachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

        case "overlay":
            guard let backend = ovsBackend else {
                throw NetworkManagerError.unsupportedDriver("overlay (requires OVS backend)")
            }
            try await backend.detachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }
    }

    /// Get vmnet interface for container (vmnet backend only, called during container creation)
    public func getVmnetInterfaceForContainer(containerID: String, networkID: String) async throws -> Any? {
        guard let backend = vmnetBackend else {
            return nil  // Not using vmnet backend
        }

        guard await backend.getNetwork(id: networkID) != nil else {
            return nil  // Network not found in vmnet backend
        }

        return try await backend.getInterfaceForContainer(containerID: containerID, networkID: networkID)
    }

    // MARK: - Network Queries

    /// Get network by ID
    public func getNetwork(id: String) async -> NetworkMetadata? {
        // Look up driver from central mapping
        guard let driver = networkDrivers[id] else {
            return nil
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge":
            switch config.networkBackend {
            case .ovs:
                return await ovsBackend?.getNetwork(id: id)
            case .vmnet:
                return await vmnetBackend?.getNetwork(id: id)
            case .wireguard:
                return await wireGuardBackend?.getNetwork(id: id)
            }

        case "vmnet":
            return await vmnetBackend?.getNetwork(id: id)

        case "wireguard":
            return await wireGuardBackend?.getNetwork(id: id)

        case "overlay":
            return await ovsBackend?.getNetwork(id: id)

        default:
            return nil
        }
    }

    /// Get network by name
    public func getNetworkByName(name: String) async -> NetworkMetadata? {
        // Look up ID from name mapping, then use efficient getNetwork by ID
        guard let id = networkNames[name] else {
            return nil
        }

        return await getNetwork(id: id)
    }

    /// Get container attachments for a network
    public func getNetworkAttachments(networkID: String) async -> [String: NetworkAttachment] {
        // Try OVS backend first
        if let backend = ovsBackend, await backend.getNetwork(id: networkID) != nil {
            return await backend.getNetworkAttachments(networkID: networkID)
        }

        // Try vmnet backend
        if let backend = vmnetBackend, await backend.getNetwork(id: networkID) != nil {
            return await backend.getNetworkAttachments(networkID: networkID)
        }

        return [:]
    }

    /// List all networks
    public func listNetworks() async -> [NetworkMetadata] {
        var networks: [NetworkMetadata] = []

        if let backend = ovsBackend {
            networks.append(contentsOf: await backend.listNetworks())
        }

        if let backend = vmnetBackend {
            networks.append(contentsOf: await backend.listNetworks())
        }

        return networks
    }

    /// Get networks for a container
    public func getContainerNetworks(containerID: String) async -> [NetworkMetadata] {
        var networks: [NetworkMetadata] = []

        if let backend = ovsBackend {
            networks.append(contentsOf: await backend.getContainerNetworks(containerID: containerID))
        }

        if vmnetBackend != nil {
            // vmnet backend doesn't track container networks separately
            // (containers are attached at creation time)
        }

        return networks
    }

    /// Resolve network ID from short ID or name
    public func resolveNetworkID(_ idOrName: String) async -> String? {
        // Try exact name match first
        if let network = await getNetworkByName(name: idOrName) {
            return network.id
        }

        // Try exact ID match
        if let network = await getNetwork(id: idOrName) {
            return network.id
        }

        // Try prefix match
        let allNetworks = await listNetworks()
        let matches = allNetworks.filter { $0.id.hasPrefix(idOrName) }

        if matches.count == 1 {
            return matches[0].id
        } else if matches.count > 1 {
            // Ambiguous - return nil
            return nil
        }

        return nil
    }

    /// Get network name by ID
    public func getNetworkName(networkID: String) async -> String? {
        return await getNetwork(id: networkID)?.name
    }

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    public func cleanupStoppedContainer(containerID: String) async {
        // Clean up in both backends (container could be in either)
        if let backend = ovsBackend {
            await backend.cleanupStoppedContainer(containerID: containerID)
        }

        if let backend = vmnetBackend {
            await backend.cleanupStoppedContainer(containerID: containerID)
        }
    }

    // MARK: - Helper Methods

    /// Generate a Docker-compatible network ID (64-char hex)
    private func generateNetworkID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Duplicate to get 64 chars
        return uuid + uuid
    }
}

// MARK: - Errors

public enum NetworkManagerError: Error, CustomStringConvertible {
    case invalidName(String)
    case nameExists(String)
    case networkNotFound(String)
    case ambiguousID(String, Int)
    case unsupportedDriver(String)
    case hasActiveEndpoints(String, Int)
    case cannotDeleteDefault
    case alreadyConnected(String, String)
    case notConnected(String, String)
    case ipAllocationFailed(String)
    case helperVMNotReady
    case containerNotFound(String)
    case dynamicAttachNotSupported(backend: String, suggestion: String)

    public var description: String {
        switch self {
        case .invalidName(let reason):
            return "Invalid network name: \(reason)"
        case .nameExists(let name):
            return "network with name \(name) already exists"
        case .networkNotFound(let id):
            return "network \(id) not found"
        case .ambiguousID(let id, let count):
            return "multiple IDs found with prefix '\(id)': \(count) IDs matched"
        case .unsupportedDriver(let driver):
            return "network driver \(driver) not supported"
        case .hasActiveEndpoints(let name, let count):
            return "network \(name) has active endpoints (\(count) containers connected)"
        case .cannotDeleteDefault:
            return "cannot remove the default bridge network"
        case .alreadyConnected(let containerID, let networkName):
            return "container \(containerID) is already connected to network \(networkName)"
        case .notConnected(let containerID, let networkName):
            return "container \(containerID) is not connected to network \(networkName)"
        case .ipAllocationFailed(let reason):
            return "IP allocation failed: \(reason)"
        case .helperVMNotReady:
            return "Network helper VM is not ready or OVN client is not connected"
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .dynamicAttachNotSupported(let backend, let suggestion):
            return "\(backend) backend does not support 'docker network connect' after container creation.\n\(suggestion)"
        }
    }
}

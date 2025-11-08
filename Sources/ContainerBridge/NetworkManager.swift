import Foundation
import Logging
import Containerization

/// Manages Docker networks with WireGuard as the default bridge backend:
/// - WireGuard backend (default): Full Docker compatibility with ~1ms latency
/// - vmnet backend: High performance native vmnet (limited features, user-created only)
///
/// NetworkManager acts as a facade that delegates to the appropriate backend
/// based on user-specified driver type.
public actor NetworkManager {
    private let config: ArcaConfig
    private let logger: Logger
    private let stateStore: StateStore
    private let containerManager: ContainerManager

    // Backends
    private var vmnetBackend: VmnetNetworkBackend?
    private var wireGuardBackend: WireGuardNetworkBackend?

    // Central network routing: networkID -> driver
    // This avoids "try all backends" pattern and provides O(1) backend lookup
    private var networkDrivers: [String: String] = [:]
    private var networkNames: [String: String] = [:]  // name -> ID mapping

    /// Initialize NetworkManager with configuration
    public init(
        config: ArcaConfig,
        stateStore: StateStore,
        containerManager: ContainerManager,
        logger: Logger
    ) {
        self.config = config
        self.stateStore = stateStore
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Initialize the network manager and backends
    public func initialize() async throws {
        logger.info("Initializing NetworkManager (WireGuard default)")

        // Always initialize WireGuard backend as the default
        let backend = WireGuardNetworkBackend(logger: logger, stateStore: stateStore)
        self.wireGuardBackend = backend

        logger.info("WireGuard backend initialized (default for bridge networks)")

        // vmnet backend is created on-demand when explicitly requested

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

        // Restore persisted networks into backend's in-memory state
        // This ensures networks created before daemon restart are available
        try await backend.restoreNetworks()

        // Create default networks (idempotent - only creates if they don't exist)
        try await createDefaultNetworks()

        logger.info("NetworkManager initialized successfully")
    }

    /// Create default Docker networks (bridge, host, none)
    /// This is idempotent - only creates networks that don't already exist
    private func createDefaultNetworks() async throws {
        logger.info("Creating default networks (if not exist)")

        // 1. Create "bridge" network (172.17.0.0/16 - Docker's default)
        if await getNetworkByName(name: "bridge") == nil {
            logger.info("Creating default 'bridge' network (172.17.0.0/16)")
            let _ = try await createNetwork(
                name: "bridge",
                driver: "bridge",
                subnet: "172.17.0.0/16",
                gateway: "172.17.0.1",
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'bridge' network")
        } else {
            logger.info("Default 'bridge' network already exists")
        }

        // 2. Create "host" network (vmnet driver - Arca's host networking equivalent)
        // Apple's vmnet framework auto-allocates subnets (e.g., 192.168.64.0/24)
        // This provides direct host networking similar to Docker's "host" mode but with an IP
        // Also serves as the underlay for WireGuard bridge network traffic (firewalled)
        if await getNetworkByName(name: "host") == nil {
            logger.info("Creating default 'host' network (vmnet driver, auto-allocated subnet)")
            let _ = try await createNetwork(
                name: "host",
                driver: "vmnet",
                subnet: nil,  // Apple auto-allocates
                gateway: nil,  // Apple auto-allocates
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'host' network")
        } else {
            logger.info("Default 'host' network already exists")
        }

        // 3. Create "none" network (null driver - no network interfaces)
        if await getNetworkByName(name: "none") == nil {
            logger.info("Creating default 'none' network (null driver)")
            let _ = try await createNetwork(
                name: "none",
                driver: "null",
                subnet: nil,
                gateway: nil,
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default 'none' network")
        } else {
            logger.info("Default 'none' network already exists")
        }

        logger.info("Default networks created successfully")
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
        // Determine effective driver (explicit driver or "bridge" as default)
        let effectiveDriver = driver ?? "bridge"

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
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            // "wireguard" is an alias for "bridge" for backwards compatibility
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }

            let metadata = try await backend.createBridgeNetwork(
                id: networkID,
                name: name,
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: options,
                labels: labels,
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = "bridge"  // Always register as "bridge"
            networkNames[name] = networkID

            return metadata.id

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
                labels: labels,
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = metadata.driver
            networkNames[name] = networkID

            return metadata.id

        case "null":
            // "null" driver - no network interfaces attached to containers
            // Used for the default "none" network
            let createdDate = Date()

            // Persist to StateStore
            let optionsJSON = try JSONEncoder().encode(options)
            let labelsJSON = try JSONEncoder().encode(labels)

            try await stateStore.saveNetwork(
                id: networkID,
                name: name,
                driver: "null",
                scope: "local",
                createdAt: createdDate,
                subnet: "",
                gateway: "",
                ipRange: nil,
                nextIPOctet: 2,  // Null networks don't use IPAM, but need default value
                optionsJSON: String(data: optionsJSON, encoding: .utf8),
                labelsJSON: String(data: labelsJSON, encoding: .utf8),
                isDefault: isDefault
            )

            // Register in mappings
            networkDrivers[networkID] = "null"
            networkNames[name] = networkID

            logger.info("Created null network", metadata: ["name": "\(name)", "id": "\(networkID)"])

            return networkID

        default:
            throw NetworkManagerError.unsupportedDriver(effectiveDriver)
        }
    }

    /// Delete a network
    public func deleteNetwork(id: String) async throws {
        // Look up driver from central mapping
        guard let driver = networkDrivers[id] else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Get metadata to check if it's a default network
        guard let metadata = await getNetwork(id: id) else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Prevent deletion of default networks
        if metadata.isDefault {
            throw NetworkManagerError.cannotDeleteDefault(metadata.name)
        }

        // Get network name for cleanup
        let networkName = metadata.name

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "vmnet":
            // Explicitly requested vmnet driver
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.deleteBridgeNetwork(id: id)

        case "null":
            // "null" driver - just remove from StateStore
            try await stateStore.deleteNetwork(id: id)
            logger.info("Deleted null network", metadata: ["id": "\(id)"])

        default:
            throw NetworkManagerError.unsupportedDriver(driver)
        }

        // Remove from mappings after successful deletion
        networkDrivers.removeValue(forKey: id)
        networkNames.removeValue(forKey: networkName)
    }

    // MARK: - Container Attachment

    /// Attach container to network
    public func attachContainerToNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String] = [],
        userSpecifiedIP: String? = nil
    ) async throws -> NetworkAttachment {
        // Look up driver from central mapping
        guard let driver = networkDrivers[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Route to appropriate backend based on driver
        switch driver {
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            return try await backend.attachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID,
                containerName: containerName,
                aliases: aliases,
                userSpecifiedIP: userSpecifiedIP
            )

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            // vmnet backend doesn't support user-specified IPs or dynamic attach
            if userSpecifiedIP != nil {
                throw NetworkManagerError.unsupportedFeature("vmnet backend does not support user-specified IPs")
            }
            // vmnet backend doesn't support dynamic attach
            try await backend.attachContainer(
                containerID: containerID,
                networkID: networkID,
                ipAddress: "",  // Not used (will throw error)
                gateway: ""     // Not used (will throw error)
            )
            fatalError("vmnet backend should have thrown dynamicAttachNotSupported")

        case "null":
            // "null" driver - no network interface attached
            // Return empty attachment (container only has loopback)
            logger.info("Skipping network attachment for null network", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
            return NetworkAttachment(
                networkID: networkID,
                ip: "",
                mac: "",
                aliases: []
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
        case "null":
            // "null" driver - nothing to detach
            logger.info("Skipping network detachment for null network", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
            return
        case "bridge", "wireguard":
            // Bridge networks always use WireGuard backend
            guard let backend = wireGuardBackend else {
                throw NetworkManagerError.backendNotReady
            }
            try await backend.detachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

        case "vmnet":
            guard let backend = vmnetBackend else {
                throw NetworkManagerError.unsupportedDriver("vmnet (backend not initialized)")
            }
            try await backend.detachContainer(containerID: containerID, networkID: networkID)

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
        case "bridge", "wireguard":
            return await wireGuardBackend?.getNetwork(id: id)

        case "vmnet":
            return await vmnetBackend?.getNetwork(id: id)

        case "null":
            // "null" driver - load from StateStore
            do {
                let allNetworks = try await stateStore.loadAllNetworks()
                guard let networkData = allNetworks.first(where: { $0.id == id }) else {
                    return nil
                }

                // Decode options and labels from JSON
                let options: [String: String]
                if let optionsJSON = networkData.optionsJSON,
                   let data = optionsJSON.data(using: .utf8) {
                    options = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                } else {
                    options = [:]
                }

                let labels: [String: String]
                if let labelsJSON = networkData.labelsJSON,
                   let data = labelsJSON.data(using: .utf8) {
                    labels = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                } else {
                    labels = [:]
                }

                return NetworkMetadata(
                    id: networkData.id,
                    name: networkData.name,
                    driver: networkData.driver,
                    subnet: networkData.subnet,
                    gateway: networkData.gateway,
                    ipRange: networkData.ipRange,  // Load ipRange from database
                    containers: [],  // Null networks don't track containers
                    created: networkData.createdAt,
                    options: options,
                    labels: labels,
                    isDefault: networkData.isDefault
                )
            } catch {
                logger.error("Failed to load null network", metadata: ["id": "\(id)", "error": "\(error)"])
                return nil
            }

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
        // Try WireGuard backend first (default for bridge)
        if let backend = wireGuardBackend, await backend.getNetwork(id: networkID) != nil {
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

        if let backend = vmnetBackend {
            networks.append(contentsOf: await backend.listNetworks())
        }

        if let backend = wireGuardBackend {
            networks.append(contentsOf: await backend.listNetworks())
        }

        // Add null driver networks from StateStore
        let nullNetworkIDs = networkDrivers.filter { $0.value == "null" }.keys
        for networkID in nullNetworkIDs {
            if let network = await getNetwork(id: networkID) {
                networks.append(network)
            }
        }

        return networks
    }

    /// Get networks for a container
    public func getContainerNetworks(containerID: String) async -> [NetworkMetadata] {
        var networks: [NetworkMetadata] = []

        if vmnetBackend != nil {
            // vmnet backend doesn't track container networks separately
            // (containers are attached at creation time)
        }

        if let backend = wireGuardBackend {
            networks.append(contentsOf: await backend.getContainerNetworks(containerID: containerID))
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

    /// Get WireGuard client for a container (for port mapping)
    /// Returns nil if container is not attached to any WireGuard networks
    public func getWireGuardClient(containerID: String) async -> WireGuardClient? {
        guard let backend = wireGuardBackend else {
            return nil
        }
        return await backend.getWireGuardClient(containerID: containerID)
    }

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    public func cleanupStoppedContainer(containerID: String) async {
        // Clean up in all backends (container could be in any)
        if let backend = vmnetBackend {
            await backend.cleanupStoppedContainer(containerID: containerID)
        }

        if let backend = wireGuardBackend {
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
    case cannotDeleteDefault(String)
    case alreadyConnected(String, String)
    case notConnected(String, String)
    case ipAllocationFailed(String)
    case backendNotReady
    case containerNotFound(String)
    case dynamicAttachNotSupported(backend: String, suggestion: String)
    case invalidIPAddress(String)
    case ipAlreadyInUse(String)
    case unsupportedFeature(String)

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
        case .cannotDeleteDefault(let name):
            return "cannot remove default network '\(name)'"
        case .alreadyConnected(let containerID, let networkName):
            return "container \(containerID) is already connected to network \(networkName)"
        case .notConnected(let containerID, let networkName):
            return "container \(containerID) is not connected to network \(networkName)"
        case .ipAllocationFailed(let reason):
            return "IP allocation failed: \(reason)"
        case .backendNotReady:
            return "Network backend is not ready"
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .dynamicAttachNotSupported(let backend, let suggestion):
            return "\(backend) backend does not support 'docker network connect' after container creation.\n\(suggestion)"
        case .invalidIPAddress(let message):
            return "Invalid IP address: \(message)"
        case .ipAlreadyInUse(let ip):
            return "IP address \(ip) is already in use"
        case .unsupportedFeature(let message):
            return "Unsupported feature: \(message)"
        }
    }
}

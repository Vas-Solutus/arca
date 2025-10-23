import Foundation
import Logging

/// Manages Docker networks using OVN/OVS via NetworkHelperVM
/// Provides translation layer between Docker Network API and OVN/OVS
/// Thread-safe via Swift actor isolation
public actor NetworkManager {
    private let helperVM: NetworkHelperVM
    private let ipamAllocator: IPAMAllocator
    private let containerManager: ContainerManager
    private let networkBridge: NetworkBridge
    private let logger: Logger

    // Network state tracking
    // Actor isolation ensures thread-safe access to all mutable state
    private var networks: [String: NetworkMetadata] = [:]  // Network ID -> Metadata
    private var networksByName: [String: String] = [:]  // Name -> Network ID
    private var containerNetworks: [String: Set<String>] = [:]  // Container ID -> Set of Network IDs
    private var deviceCounter: [String: Int] = [:]  // Container ID -> next device index (eth0, eth1, etc.)

    /// Metadata for a Docker network
    public struct NetworkMetadata: Sendable {
        public let id: String
        public let name: String
        public let driver: String
        public let subnet: String
        public let gateway: String
        public var containers: Set<String>  // Container IDs
        public let created: Date
        public let options: [String: String]
        public let labels: [String: String]
        public let isDefault: Bool  // true for "bridge" default network

        public init(
            id: String,
            name: String,
            driver: String,
            subnet: String,
            gateway: String,
            containers: Set<String> = [],
            created: Date = Date(),
            options: [String: String] = [:],
            labels: [String: String] = [:],
            isDefault: Bool = false
        ) {
            self.id = id
            self.name = name
            self.driver = driver
            self.subnet = subnet
            self.gateway = gateway
            self.containers = containers
            self.created = created
            self.options = options
            self.labels = labels
            self.isDefault = isDefault
        }
    }

    /// Metadata for a container's network attachment
    public struct NetworkAttachment: Sendable {
        public let networkID: String
        public let ip: String
        public let mac: String
        public let aliases: [String]

        public init(networkID: String, ip: String, mac: String, aliases: [String] = []) {
            self.networkID = networkID
            self.ip = ip
            self.mac = mac
            self.aliases = aliases
        }
    }

    public init(helperVM: NetworkHelperVM, ipamAllocator: IPAMAllocator, containerManager: ContainerManager, networkBridge: NetworkBridge, logger: Logger) {
        self.helperVM = helperVM
        self.ipamAllocator = ipamAllocator
        self.containerManager = containerManager
        self.networkBridge = networkBridge
        self.logger = logger
    }

    /// Initialize the network manager and create default "bridge" network
    public func initialize() async throws {
        logger.info("Initializing NetworkManager")

        // Ensure helper VM is initialized and started
        try await helperVM.initialize()
        try await helperVM.start()

        // Create default "bridge" network if it doesn't exist
        if networksByName["bridge"] == nil {
            logger.info("Creating default 'bridge' network")
            let bridgeID = try await createNetwork(
                name: "bridge",
                driver: "bridge",
                subnet: "172.17.0.0/16",
                gateway: "172.17.0.1",
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default bridge network", metadata: ["id": "\(bridgeID)"])
        }

        logger.info("NetworkManager initialized successfully")
    }

    // MARK: - Network CRUD Operations

    /// Create a new network
    public func createNetwork(
        name: String,
        driver: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) async throws -> String {
        logger.info("Creating network", metadata: [
            "name": "\(name)",
            "driver": "\(driver)",
            "subnet": "\(subnet ?? "auto")"
        ])

        // Validate network name
        guard !name.isEmpty else {
            throw NetworkManagerError.invalidName("Network name cannot be empty")
        }

        // Check for duplicate name
        if networksByName[name] != nil {
            throw NetworkManagerError.nameExists(name)
        }

        // Validate driver (only support "bridge" for now)
        guard driver == "bridge" else {
            throw NetworkManagerError.unsupportedDriver(driver)
        }

        // Allocate subnet if not provided
        let (finalSubnet, finalGateway): (String, String)
        if let subnet = subnet {
            // Use provided subnet/gateway
            finalSubnet = subnet
            if let gw = gateway {
                finalGateway = gw
            } else {
                finalGateway = await ipamAllocator.calculateGateway(subnet: subnet)
            }
        } else {
            // Auto-allocate subnet for custom networks
            (finalSubnet, finalGateway) = try await ipamAllocator.allocateSubnet()
        }

        // Generate Docker network ID (64-char hex)
        let networkID = generateNetworkID()

        // Create bridge in helper VM via OVN
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        let bridgeName = try await ovnClient.createBridge(
            networkID: networkID,
            subnet: finalSubnet,
            gateway: finalGateway
        )

        logger.debug("Bridge created in helper VM", metadata: ["bridge": "\(bridgeName)"])

        // Store network metadata
        let metadata = NetworkMetadata(
            id: networkID,
            name: name,
            driver: driver,
            subnet: finalSubnet,
            gateway: finalGateway,
            containers: [],
            created: Date(),
            options: options,
            labels: labels,
            isDefault: isDefault
        )
        networks[networkID] = metadata
        networksByName[name] = networkID

        logger.info("Network created successfully", metadata: [
            "id": "\(networkID)",
            "name": "\(name)",
            "subnet": "\(finalSubnet)",
            "gateway": "\(finalGateway)"
        ])

        return networkID
    }

    /// Delete a network
    public func deleteNetwork(id: String, force: Bool = false) async throws {
        logger.info("Deleting network", metadata: ["id": "\(id)", "force": "\(force)"])

        // Resolve network ID (support short IDs and names)
        let networkID = try resolveNetworkID(id)

        guard let metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Prevent deletion of default bridge network
        if metadata.isDefault {
            throw NetworkManagerError.cannotDeleteDefault
        }

        // Check if containers are attached
        if !metadata.containers.isEmpty && !force {
            throw NetworkManagerError.hasActiveEndpoints(metadata.name, metadata.containers.count)
        }

        // Delete bridge from helper VM
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        try await ovnClient.deleteBridge(networkID: networkID)

        // Clean up metadata
        networks.removeValue(forKey: networkID)
        networksByName.removeValue(forKey: metadata.name)

        // Clean up container mappings
        for containerID in metadata.containers {
            containerNetworks[containerID]?.remove(networkID)
        }

        logger.info("Network deleted successfully", metadata: ["id": "\(networkID)"])
    }

    /// List networks with optional filters
    public func listNetworks(filters: [String: [String]] = [:]) async throws -> [NetworkMetadata] {
        var result = Array(networks.values)

        // Apply filters
        if let names = filters["name"], !names.isEmpty {
            result = result.filter { names.contains($0.name) }
        }
        if let ids = filters["id"], !ids.isEmpty {
            result = result.filter { id in ids.contains(where: { id.id.hasPrefix($0) }) }
        }
        if let drivers = filters["driver"], !drivers.isEmpty {
            result = result.filter { drivers.contains($0.driver) }
        }
        if let types = filters["type"], !types.isEmpty {
            // Support "builtin" (default networks) and "custom"
            result = result.filter { network in
                types.contains(network.isDefault ? "builtin" : "custom")
            }
        }

        return result.sorted { $0.created < $1.created }
    }

    /// Inspect a specific network
    public func inspectNetwork(id: String) async throws -> NetworkMetadata {
        let networkID = try resolveNetworkID(id)
        guard let metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(id)
        }
        return metadata
    }

    // MARK: - Container Network Operations

    /// Connect a container to a network
    public func connectContainer(
        containerID: String,
        containerName: String,
        networkID: String,
        ipv4Address: String?,
        aliases: [String]
    ) async throws -> NetworkAttachment {
        logger.info("Connecting container to network", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)"
        ])

        let resolvedNetworkID = try resolveNetworkID(networkID)
        guard var metadata = networks[resolvedNetworkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Check if already connected
        if metadata.containers.contains(containerID) {
            throw NetworkManagerError.alreadyConnected(containerID, metadata.name)
        }

        // Allocate IP address
        let ip = try await ipamAllocator.allocateIP(
            networkID: resolvedNetworkID,
            subnet: metadata.subnet,
            preferredIP: ipv4Address
        )

        // Generate MAC address
        let mac = generateMACAddress()

        // Attach container to OVS bridge in helper VM
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        let portName = try await ovnClient.attachContainer(
            containerID: containerID,
            networkID: resolvedNetworkID,
            ipAddress: ip,
            macAddress: mac,
            hostname: containerName,
            aliases: aliases
        )

        logger.debug("Container attached to OVS bridge", metadata: [
            "port": "\(portName)",
            "ip": "\(ip)",
            "mac": "\(mac)"
        ])

        // Determine device name (eth0, eth1, etc.)
        let deviceIndex = deviceCounter[containerID] ?? 0
        let device = "eth\(deviceIndex)"
        deviceCounter[containerID] = deviceIndex + 1

        // Get container's LinuxContainer reference for vsock communication
        guard let container = try await containerManager.getLinuxContainer(dockerID: containerID) else {
            throw NetworkManagerError.containerNotFound(containerID)
        }

        // Attach container to network via NetworkBridge (creates TAP device and starts relay)
        try await networkBridge.attachContainerToNetwork(
            container: container,
            containerID: containerID,
            networkID: resolvedNetworkID,
            ipAddress: ip,
            gateway: metadata.gateway,
            device: device
        )

        logger.info("TAP device created and relay started", metadata: [
            "device": "\(device)",
            "ip": "\(ip)"
        ])

        // Update ContainerManager's network attachment tracking
        try await containerManager.attachContainerToNetwork(
            dockerID: containerID,
            networkID: resolvedNetworkID,
            ip: ip,
            mac: mac,
            aliases: aliases
        )

        // Track IP allocation
        await ipamAllocator.trackAllocation(networkID: resolvedNetworkID, containerID: containerID, ip: ip)

        // Update metadata
        metadata.containers.insert(containerID)
        networks[resolvedNetworkID] = metadata

        // Track container's networks
        if containerNetworks[containerID] == nil {
            containerNetworks[containerID] = []
        }
        containerNetworks[containerID]?.insert(resolvedNetworkID)

        logger.info("Container connected to network", metadata: [
            "container": "\(containerID)",
            "network": "\(metadata.name)",
            "ip": "\(ip)",
            "mac": "\(mac)"
        ])

        return NetworkAttachment(
            networkID: resolvedNetworkID,
            ip: ip,
            mac: mac,
            aliases: aliases
        )
    }

    /// Disconnect a container from a network
    public func disconnectContainer(containerID: String, networkID: String, force: Bool = false) async throws {
        logger.info("Disconnecting container from network", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)",
            "force": "\(force)"
        ])

        let resolvedNetworkID = try resolveNetworkID(networkID)
        guard var metadata = networks[resolvedNetworkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Check if connected
        guard metadata.containers.contains(containerID) else {
            throw NetworkManagerError.notConnected(containerID, metadata.name)
        }

        // Detach container from OVS bridge in helper VM
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        try await ovnClient.detachContainer(containerID: containerID, networkID: resolvedNetworkID)

        // Detach container from network via NetworkBridge (stops relay and removes TAP device)
        if let container = try await containerManager.getLinuxContainer(dockerID: containerID) {
            do {
                try await networkBridge.detachContainerFromNetwork(
                    container: container,
                    containerID: containerID,
                    networkID: resolvedNetworkID
                )
                logger.info("TAP device removed and relay stopped", metadata: [
                    "containerID": "\(containerID)",
                    "networkID": "\(resolvedNetworkID)"
                ])
            } catch {
                logger.error("Failed to detach via NetworkBridge", metadata: [
                    "error": "\(error)"
                ])
                // Continue with cleanup even if NetworkBridge detachment fails
            }
        } else {
            logger.warning("Container not found for NetworkBridge detachment", metadata: [
                "containerID": "\(containerID)"
            ])
            // Continue with cleanup even if container reference is not available
        }

        // Update ContainerManager's network attachment tracking
        try await containerManager.detachContainerFromNetwork(
            dockerID: containerID,
            networkID: resolvedNetworkID
        )

        // Release IP address (tracked internally by IPAMAllocator)
        await ipamAllocator.releaseIP(networkID: resolvedNetworkID, containerID: containerID)

        // Update metadata
        metadata.containers.remove(containerID)
        networks[resolvedNetworkID] = metadata

        // Update container mappings
        containerNetworks[containerID]?.remove(resolvedNetworkID)

        logger.info("Container disconnected from network", metadata: [
            "container": "\(containerID)",
            "network": "\(metadata.name)"
        ])
    }

    /// Get all networks a container is connected to
    public func getContainerNetworks(containerID: String) -> [String] {
        return Array(containerNetworks[containerID] ?? [])
    }

    // MARK: - Helper Methods

    /// Resolve network ID from full ID, short ID, or name
    private func resolveNetworkID(_ idOrName: String) throws -> String {
        // Try exact name match first
        if let networkID = networksByName[idOrName] {
            return networkID
        }

        // Try exact ID match
        if networks[idOrName] != nil {
            return idOrName
        }

        // Try short ID match (4+ hex chars)
        if idOrName.count >= 4 && idOrName.allSatisfy(\.isHexDigit) {
            let matches = networks.keys.filter { $0.hasPrefix(idOrName) }
            if matches.count == 1 {
                return matches.first!
            } else if matches.count > 1 {
                throw NetworkManagerError.ambiguousID(idOrName, matches.count)
            }
        }

        throw NetworkManagerError.networkNotFound(idOrName)
    }

    /// Generate a Docker-style network ID (64-char hex)
    private func generateNetworkID() -> String {
        // Generate UUID and convert to hex string, then duplicate to reach 64 chars
        let uuid = UUID()
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return hex + hex  // 32 chars * 2 = 64 chars
    }

    /// Generate a MAC address for a container NIC
    /// Format: 02:XX:XX:XX:XX:XX (locally administered, unicast)
    private func generateMACAddress() -> String {
        var bytes: [UInt8] = [0x02]  // Locally administered, unicast
        for _ in 0..<5 {
            bytes.append(UInt8.random(in: 0...255))
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
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
            return "network driver \(driver) not supported (only 'bridge' is supported)"
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
        }
    }
}

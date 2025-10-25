import Foundation
import Logging
import Containerization

/// OVS/OVN backend for Docker bridge and overlay networks
///
/// Provides full Docker Network API compatibility using:
/// - TAP-over-vsock for container networking
/// - OVS/OVN helper VM for bridge switching and routing
/// - NetworkBridge for packet relay between containers and helper VM
///
/// **Features:**
/// - Dynamic network attachment (docker network connect/disconnect)
/// - Multi-network containers (eth0, eth1, eth2...)
/// - Port mapping via OVS DNAT
/// - Network isolation via separate OVS bridges
/// - SNAT for internet access
/// - Future: VXLAN overlay networks
///
/// **Performance:**
/// - ~4-7ms latency (acceptable for development)
/// - 4 vsock hops per packet
public actor OVSNetworkBackend {
    private let helperVM: NetworkHelperVM
    private let ipamAllocator: IPAMAllocator
    private let networkBridge: NetworkBridge
    private let logger: Logger

    // Network state tracking
    private var networks: [String: NetworkMetadata] = [:]  // Network ID -> Metadata
    private var networksByName: [String: String] = [:]  // Name -> Network ID
    private var containerNetworks: [String: Set<String>] = [:]  // Container ID -> Set of Network IDs
    private var deviceCounter: [String: Int] = [:]  // Container ID -> next device index (eth0, eth1, etc.)
    private var portAllocator: PortAllocator  // vsock port allocator for TAP forwarding

    public init(
        helperVM: NetworkHelperVM,
        ipamAllocator: IPAMAllocator,
        networkBridge: NetworkBridge,
        logger: Logger
    ) {
        self.helperVM = helperVM
        self.ipamAllocator = ipamAllocator
        self.networkBridge = networkBridge
        self.logger = logger
        self.portAllocator = PortAllocator(basePort: 20000)
    }

    // MARK: - Initialization

    /// Initialize OVS backend and create default bridge network
    public func initialize() async throws {
        logger.info("Initializing OVS network backend")

        // Verify helper VM is ready
        guard await helperVM.getOVNClient() != nil else {
            throw NetworkManagerError.helperVMNotReady
        }

        // Create default "bridge" network if it doesn't exist
        if networksByName["bridge"] == nil {
            logger.info("Creating default 'bridge' network")
            let metadata = try await createBridgeNetwork(
                id: generateNetworkID(),
                name: "bridge",
                subnet: "172.17.0.0/16",
                gateway: "172.17.0.1",
                ipRange: nil,
                options: [:],
                labels: [:],
                isDefault: true
            )
            logger.info("Created default bridge network", metadata: ["id": "\(metadata.id)"])
        }

        logger.info("OVS network backend initialized successfully")
    }

    // MARK: - Network Creation

    /// Create a new bridge network using OVS
    public func createBridgeNetwork(
        id: String,
        name: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) async throws -> NetworkMetadata {
        logger.info("Creating OVS bridge network", metadata: [
            "network_id": "\(id)",
            "network_name": "\(name)",
            "subnet": "\(subnet ?? "auto")"
        ])

        // Determine subnet (use provided or auto-allocate from 172.18-31.0.0/16 range)
        let effectiveSubnet: String
        let effectiveGateway: String

        if let subnet = subnet {
            effectiveSubnet = subnet
            effectiveGateway = gateway ?? calculateGateway(subnet: subnet)
        } else {
            // Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16
            let (allocatedSubnet, allocatedGateway) = try await ipamAllocator.allocateSubnet()
            effectiveSubnet = allocatedSubnet
            effectiveGateway = allocatedGateway
        }

        // Create OVS bridge in helper VM
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        _ = try await ovnClient.createBridge(
            networkID: id,
            subnet: effectiveSubnet,
            gateway: effectiveGateway
        )

        logger.info("OVS bridge created in helper VM", metadata: [
            "network_id": "\(id)",
            "subnet": "\(effectiveSubnet)",
            "gateway": "\(effectiveGateway)"
        ])

        // Create metadata
        let metadata = NetworkMetadata(
            id: id,
            name: name,
            driver: "bridge",
            subnet: effectiveSubnet,
            gateway: effectiveGateway,
            containers: [],
            created: Date(),
            options: options,
            labels: labels,
            isDefault: isDefault
        )

        networks[id] = metadata
        networksByName[name] = id

        return metadata
    }

    /// Create an overlay network using OVN (future implementation)
    public func createOverlayNetwork(
        id: String,
        name: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String]
    ) async throws -> NetworkMetadata {
        // TODO: Implement VXLAN overlay networks with OVN
        throw NetworkManagerError.unsupportedDriver("overlay (not yet implemented)")
    }

    /// Delete a network
    public func deleteNetwork(id: String) async throws {
        guard let metadata = networks[id] else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Cannot delete default bridge network
        if metadata.isDefault {
            throw NetworkManagerError.cannotDeleteDefault
        }

        // Check if network has active endpoints
        if !metadata.containers.isEmpty {
            throw NetworkManagerError.hasActiveEndpoints(metadata.name, metadata.containers.count)
        }

        logger.info("Deleting OVS bridge network", metadata: [
            "network_id": "\(id)",
            "name": "\(metadata.name)"
        ])

        // Delete OVS bridge from helper VM
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        try await ovnClient.deleteBridge(networkID: id)

        // Remove from tracking
        networks.removeValue(forKey: id)
        networksByName.removeValue(forKey: metadata.name)

        logger.info("OVS bridge network deleted", metadata: ["network_id": "\(id)"])
    }

    // MARK: - Container Attachment

    /// Attach container to network (dynamic - can be called after container creation)
    public func attachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String] = []
    ) async throws -> NetworkAttachment {
        guard let metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Check if already connected
        if let existingNetworks = containerNetworks[containerID],
           existingNetworks.contains(networkID) {
            throw NetworkManagerError.alreadyConnected(containerID, metadata.name)
        }

        logger.info("Attaching container to OVS network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "network_name": "\(metadata.name)"
        ])

        // Allocate IP address
        let ipAddress = try await ipamAllocator.allocateIP(networkID: networkID, subnet: metadata.subnet, preferredIP: nil)

        // Track the allocation immediately
        await ipamAllocator.trackAllocation(networkID: networkID, containerID: containerID, ip: ipAddress)

        let macAddress = generateMACAddress()

        // Determine device name (eth0, eth1, etc.)
        let deviceIndex = deviceCounter[containerID, default: 0]
        let deviceName = "eth\(deviceIndex)"
        deviceCounter[containerID] = deviceIndex + 1

        // Allocate vsock port for TAP forwarding
        let containerPort = try await portAllocator.allocate()

        // Tell helper VM to set up relay listener
        // This must happen BEFORE networkBridge tries to connect
        guard let ovnClient = await helperVM.getOVNClient() else {
            throw NetworkManagerError.helperVMNotReady
        }

        _ = try await ovnClient.attachContainer(
            containerID: containerID,
            networkID: networkID,
            ipAddress: ipAddress,
            macAddress: macAddress,
            hostname: containerName,
            aliases: aliases,
            vsockPort: containerPort
        )

        // Attach to network bridge via NetworkBridge
        try await networkBridge.attachContainerToNetwork(
            container: container,
            containerID: containerID,
            networkID: networkID,
            ipAddress: ipAddress,
            gateway: metadata.gateway,
            device: deviceName,
            containerPort: containerPort
        )

        // Update tracking
        var updatedMetadata = metadata
        updatedMetadata.containers.insert(containerID)
        networks[networkID] = updatedMetadata

        if containerNetworks[containerID] == nil {
            containerNetworks[containerID] = []
        }
        containerNetworks[containerID]?.insert(networkID)

        logger.info("Container attached to OVS network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "device": "\(deviceName)",
            "ip": "\(ipAddress)"
        ])

        return NetworkAttachment(
            networkID: networkID,
            ip: ipAddress,
            mac: macAddress,
            aliases: aliases
        )
    }

    /// Detach container from network
    public func detachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        guard var metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        // Check if connected
        guard containerNetworks[containerID]?.contains(networkID) == true else {
            throw NetworkManagerError.notConnected(containerID, metadata.name)
        }

        logger.info("Detaching container from OVS network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])

        // Detach from network bridge
        try await networkBridge.detachContainerFromNetwork(
            container: container,
            containerID: containerID,
            networkID: networkID
        )

        // Release IP address
        await ipamAllocator.releaseIP(networkID: networkID, containerID: containerID)

        // Update tracking
        metadata.containers.remove(containerID)
        networks[networkID] = metadata

        containerNetworks[containerID]?.remove(networkID)
        if containerNetworks[containerID]?.isEmpty == true {
            containerNetworks.removeValue(forKey: containerID)
            deviceCounter.removeValue(forKey: containerID)
        }

        logger.info("Container detached from OVS network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])
    }

    // MARK: - Network Queries

    /// Get network metadata by ID
    public func getNetwork(id: String) -> NetworkMetadata? {
        return networks[id]
    }

    /// Get network metadata by name
    public func getNetworkByName(name: String) -> NetworkMetadata? {
        guard let id = networksByName[name] else { return nil }
        return networks[id]
    }

    /// List all networks
    public func listNetworks() -> [NetworkMetadata] {
        return Array(networks.values)
    }

    /// Get networks for a container
    public func getContainerNetworks(containerID: String) -> [NetworkMetadata] {
        guard let networkIDs = containerNetworks[containerID] else { return [] }
        return networkIDs.compactMap { networks[$0] }
    }

    // MARK: - Helper Methods

    /// Generate a Docker-compatible network ID (64-char hex)
    private func generateNetworkID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Duplicate to get 64 chars
        return uuid + uuid
    }

    /// Calculate gateway IP from subnet
    private func calculateGateway(subnet: String) -> String {
        // Simple implementation: use .1 as gateway
        // e.g., 172.18.0.0/16 -> 172.18.0.1
        let parts = subnet.split(separator: "/")
        guard let networkPart = parts.first else { return subnet }
        let octets = networkPart.split(separator: ".")
        guard octets.count == 4 else { return String(networkPart) }

        // Replace last octet with .1
        return "\(octets[0]).\(octets[1]).\(octets[2]).1"
    }

    /// Generate a random MAC address
    private func generateMACAddress() -> String {
        // Docker uses 02:42:xx:xx:xx:xx range
        let bytes = (0..<4).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        return "02:42:\(bytes.joined(separator: ":"))"
    }
}

// NetworkMetadata and NetworkAttachment are defined in NetworkTypes.swift to avoid duplication

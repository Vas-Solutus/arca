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
    private let stateStore: StateStore
    private let ovnClient: OVNClient
    private let networkBridge: NetworkBridge
    private let logger: Logger

    // Network state tracking
    private var networks: [String: NetworkMetadata] = [:]  // Network ID -> Metadata
    private var networksByName: [String: String] = [:]  // Name -> Network ID
    private var containerNetworks: [String: Set<String>] = [:]  // Container ID -> Set of Network IDs
    private var deviceCounter: [String: Int] = [:]  // Container ID -> next device index (eth0, eth1, etc.)
    private var portAllocator: PortAllocator  // vsock port allocator for TAP forwarding

    // Subnet allocation tracking (simple counter for auto-allocation)
    // Used to assign different subnets to different networks (172.18.x.x, 172.19.x.x, etc.)
    // Note: This is separate from IP allocation within a subnet (which OVN DHCP handles)
    private var nextSubnetByte: UInt8 = 18  // Start at 172.18.0.0/16

    // Container attachment details: networkID -> containerID -> (ip, mac, aliases)
    private var containerAttachments: [String: [String: NetworkAttachment]] = [:]

    public init(
        stateStore: StateStore,
        ovnClient: OVNClient,
        networkBridge: NetworkBridge,
        logger: Logger
    ) {
        self.stateStore = stateStore
        self.ovnClient = ovnClient
        self.networkBridge = networkBridge
        self.logger = logger
        self.portAllocator = PortAllocator(basePort: 20000)
    }

    // MARK: - Initialization

    /// Initialize OVS backend and create default bridge network
    public func initialize() async throws {
        logger.info("Initializing OVS network backend")

        // Verify OVN client is ready (already connected in NetworkManager)
        logger.debug("OVN client ready for network operations")

        // Load persisted networks from StateStore
        do {
            let persistedNetworks = try await stateStore.loadAllNetworks()
            logger.info("Loaded persisted networks", metadata: ["count": "\(persistedNetworks.count)"])

            for network in persistedNetworks {
                // Decode options and labels from JSON
                let options: [String: String]
                if let optionsJSON = network.optionsJSON,
                   let optionsData = optionsJSON.data(using: .utf8) {
                    options = (try? JSONDecoder().decode([String: String].self, from: optionsData)) ?? [:]
                } else {
                    options = [:]
                }

                let labels: [String: String]
                if let labelsJSON = network.labelsJSON,
                   let labelsData = labelsJSON.data(using: .utf8) {
                    labels = (try? JSONDecoder().decode([String: String].self, from: labelsData)) ?? [:]
                } else {
                    labels = [:]
                }

                // Reconstruct metadata
                let metadata = NetworkMetadata(
                    id: network.id,
                    name: network.name,
                    driver: network.driver,
                    subnet: network.subnet,
                    gateway: network.gateway,
                    containers: [],  // Will be populated from attachments
                    created: network.createdAt,
                    options: options,
                    labels: labels,
                    isDefault: network.isDefault
                )

                networks[network.id] = metadata
                networksByName[network.name] = network.id

                logger.debug("Restored network from database", metadata: [
                    "id": "\(network.id)",
                    "name": "\(network.name)",
                    "subnet": "\(network.subnet)"
                ])

                // Recreate bridge in OVN (reconciliation)
                // After daemon restart, networks exist in database but not in OVN control plane
                // We need to recreate them in OVN to restore full functionality
                do {
                    _ = try await ovnClient.createBridge(
                        networkID: network.id,
                        subnet: network.subnet,
                        gateway: network.gateway
                    )
                    logger.info("Recreated network bridge in OVN during reconciliation", metadata: [
                        "id": "\(network.id)",
                        "name": "\(network.name)"
                    ])
                } catch {
                    logger.error("Failed to recreate network bridge in OVN", metadata: [
                        "id": "\(network.id)",
                        "name": "\(network.name)",
                        "error": "\(error)"
                    ])
                    // Continue - network will be in database but not functional
                }

                // Update subnet allocation tracking
                if let subnetByte = extractSubnetByte(from: network.subnet) {
                    if subnetByte >= nextSubnetByte {
                        nextSubnetByte = subnetByte + 1
                    }
                }
            }

            // Update StateStore with current subnet allocation counter
            try await stateStore.updateNextSubnetByte(Int(nextSubnetByte))

        } catch {
            logger.error("Failed to load persisted networks", metadata: ["error": "\(error)"])
            // Continue - will create default network below
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

        logger.info("OVS network backend initialized successfully", metadata: [
            "networks": "\(networks.count)"
        ])
    }

    /// Extract the third octet from a subnet CIDR (e.g., "172.18.0.0/16" -> 18)
    private func extractSubnetByte(from subnet: String) -> UInt8? {
        let components = subnet.split(separator: "/")[0].split(separator: ".")
        guard components.count >= 3,
              let byte = UInt8(components[2]) else {
            return nil
        }
        return byte
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
            // Simple counter-based allocation
            effectiveSubnet = "172.\(nextSubnetByte).0.0/16"
            effectiveGateway = "172.\(nextSubnetByte).0.1"
            nextSubnetByte += 1
            if nextSubnetByte > 31 {
                nextSubnetByte = 18  // Wrap around
            }

            // Persist updated subnet allocation counter
            do {
                try await stateStore.updateNextSubnetByte(Int(nextSubnetByte))
            } catch {
                logger.error("Failed to persist subnet allocation counter", metadata: ["error": "\(error)"])
                // Continue - in-memory state is still valid
            }
        }

        // Create OVS bridge in control plane
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

        // Persist network to StateStore
        do {
            let optionsJSON = options.isEmpty ? nil : try? String(data: JSONEncoder().encode(options), encoding: .utf8)
            let labelsJSON = labels.isEmpty ? nil : try? String(data: JSONEncoder().encode(labels), encoding: .utf8)

            try await stateStore.saveNetwork(
                id: id,
                name: name,
                driver: "bridge",
                scope: "local",
                createdAt: metadata.created,
                subnet: effectiveSubnet,
                gateway: effectiveGateway,
                ipRange: ipRange,
                optionsJSON: optionsJSON,
                labelsJSON: labelsJSON,
                isDefault: isDefault
            )

            logger.debug("Network persisted to database", metadata: ["id": "\(id)"])
        } catch {
            logger.error("Failed to persist network to database", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            // Continue - in-memory state is still valid
        }

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

        // Delete OVS bridge from control plane
        try await ovnClient.deleteBridge(networkID: id)

        // Remove from tracking
        networks.removeValue(forKey: id)
        networksByName.removeValue(forKey: metadata.name)

        // Delete from StateStore
        do {
            try await stateStore.deleteNetwork(id: id)
            logger.debug("Network deleted from database", metadata: ["id": "\(id)"])
        } catch {
            logger.error("Failed to delete network from database", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            // Continue - in-memory state is already updated
        }

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

        // Use dynamic DHCP allocation (OVN will assign IP automatically)
        let macAddress = generateMACAddress()

        // Determine device name (eth0, eth1, etc.)
        let deviceIndex = deviceCounter[containerID, default: 0]
        let deviceName = "eth\(deviceIndex)"
        deviceCounter[containerID] = deviceIndex + 1

        // Allocate vsock port for TAP forwarding
        let containerPort = try await portAllocator.allocate()

        // Tell control plane to set up relay listener
        // This must happen BEFORE networkBridge tries to connect
        // Attach to OVN - this will allocate IP via DHCP and return it
        let response = try await ovnClient.attachContainer(
            containerID: containerID,
            networkID: networkID,
            ipAddress: "", // Empty = dynamic DHCP
            macAddress: macAddress,
            hostname: containerName,
            aliases: aliases,
            vsockPort: containerPort
        )

        // Get the allocated IP from the response
        let ipAddress = response.ipAddress

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

        // Store attachment details for network inspect
        if containerAttachments[networkID] == nil {
            containerAttachments[networkID] = [:]
        }
        let attachment = NetworkAttachment(
            networkID: networkID,
            ip: ipAddress,
            mac: macAddress,
            aliases: aliases
        )
        containerAttachments[networkID]![containerID] = attachment

        // Persist attachment to StateStore
        do {
            try await stateStore.saveNetworkAttachment(
                containerID: containerID,
                networkID: networkID,
                ipAddress: ipAddress,
                macAddress: macAddress,
                aliases: aliases
            )
            logger.debug("Network attachment persisted to database", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        } catch {
            logger.error("Failed to persist network attachment to database", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "error": "\(error)"
            ])
            // Continue - in-memory state is still valid
        }

        logger.info("Container attached to OVS network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "device": "\(deviceName)",
            "ip": "\(ipAddress)"
        ])

        return attachment
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

        // TODO: Release IP from OVN DHCP
        // OVN will handle IP release automatically when logical switch port is deleted

        // Update tracking
        metadata.containers.remove(containerID)
        networks[networkID] = metadata

        containerNetworks[containerID]?.remove(networkID)
        if containerNetworks[containerID]?.isEmpty == true {
            containerNetworks.removeValue(forKey: containerID)
            deviceCounter.removeValue(forKey: containerID)
        }

        // Remove attachment details
        containerAttachments[networkID]?.removeValue(forKey: containerID)

        // Delete attachment from StateStore
        do {
            try await stateStore.deleteNetworkAttachment(containerID: containerID, networkID: networkID)
            logger.debug("Network attachment deleted from database", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        } catch {
            logger.error("Failed to delete network attachment from database", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "error": "\(error)"
            ])
            // Continue - in-memory state is already updated
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

    /// Get container attachments for a network
    public func getNetworkAttachments(networkID: String) -> [String: NetworkAttachment] {
        return containerAttachments[networkID] ?? [:]
    }

    // MARK: - Helper Methods

    /// Generate a Docker-compatible network ID (64-char hex)
    private func generateNetworkID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Duplicate to get 64 chars
        return uuid + uuid
    }

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

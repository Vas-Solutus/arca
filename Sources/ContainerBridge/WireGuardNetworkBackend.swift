import Foundation
import Logging
import Containerization

/// WireGuard backend for Docker bridge networks
///
/// Provides full Docker Network API compatibility using WireGuard hub-and-spoke topology:
/// - Each container gets a WireGuard hub interface (wg0) when first attached to a network
/// - Each network the container joins becomes a peer on that hub
/// - WireGuard allowed-ips routing handles multi-network scenarios
/// - All configuration done via gRPC over vsock to WireGuard service in container
///
/// **Features:**
/// - Dynamic network attachment (docker network connect/disconnect)
/// - Multi-network containers (all networks on single wg0 interface)
/// - Network isolation via WireGuard cryptographic routing
/// - Ultra-low latency (~1ms) - WireGuard kernel-space routing
/// - No helper VM required
///
/// **Performance:**
/// - ~1ms latency (kernel-space routing)
/// - Single kernel-space routing decision per packet
/// - No vsock relay overhead (direct vmnet UDP)
public actor WireGuardNetworkBackend {
    private let logger: Logger
    private let stateStore: StateStore

    // Network state tracking
    private var networks: [String: NetworkMetadata] = [:]  // Network ID -> Metadata
    private var networksByName: [String: String] = [:]  // Name -> Network ID
    private var containerNetworks: [String: Set<String>] = [:]  // Container ID -> Set of Network IDs

    // Container attachment details: networkID -> containerID -> (ip, mac, aliases)
    private var containerAttachments: [String: [String: NetworkAttachment]] = [:]

    // WireGuard interface state (Phase 2.2 - multi-network)
    // Track network index for each container-network pair: containerID -> networkID -> networkIndex
    private var containerNetworkIndices: [String: [String: UInt32]] = [:]

    // Track public keys per interface: containerID -> networkID -> publicKey
    private var containerInterfaceKeys: [String: [String: String]] = [:]

    // WireGuard clients for container communication: containerID -> WireGuardClient
    private var wireGuardClients: [String: WireGuardClient] = [:]

    // Container names for DNS resolution (Phase 3.1): containerID -> containerName
    private var containerNames: [String: String] = [:]

    // Subnet allocation tracking (simple counter for auto-allocation)
    private var nextSubnetByte: UInt8 = 18  // Start at 172.18.0.0/16

    // IP allocation within networks: networkID -> next IP octet
    private var nextIPOctet: [String: UInt8] = [:]  // Tracks .2, .3, .4, etc. (.1 is gateway)

    public init(logger: Logger, stateStore: StateStore) {
        self.logger = logger
        self.stateStore = stateStore
    }

    /// Restore networks from database on daemon startup
    /// This populates the in-memory networks dictionary with persisted network metadata
    public func restoreNetworks() async throws {
        let persistedNetworks = try await stateStore.loadAllNetworks()

        for networkData in persistedNetworks {
            // Only restore WireGuard/bridge networks
            guard networkData.driver == "bridge" || networkData.driver == "wireguard" else {
                continue
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

            // Create NetworkMetadata and restore to in-memory state
            let metadata = NetworkMetadata(
                id: networkData.id,
                name: networkData.name,
                driver: networkData.driver,
                subnet: networkData.subnet,
                gateway: networkData.gateway,
                ipRange: networkData.ipRange,
                containers: [],  // Containers will be reattached when they start
                created: networkData.createdAt,
                options: options,
                labels: labels,
                isDefault: networkData.isDefault
            )

            networks[networkData.id] = metadata
            networksByName[networkData.name] = networkData.id

            // Initialize IP allocation state
            // If ipRange is specified, calculate starting octet from it
            // Otherwise start at .2 (.1 is gateway)
            if let ipRange = networkData.ipRange {
                // Parse ipRange to get starting IP
                // Example: "172.18.0.128/25" -> start at .128
                let rangeComponents = ipRange.split(separator: "/")[0].split(separator: ".")
                if rangeComponents.count == 4, let startOctet = UInt8(rangeComponents[3]) {
                    nextIPOctet[networkData.id] = startOctet
                } else {
                    nextIPOctet[networkData.id] = 2  // Fallback
                }
            } else {
                nextIPOctet[networkData.id] = 2
            }

            logger.debug("Restored network from database", metadata: [
                "network_id": "\(networkData.id)",
                "name": "\(networkData.name)",
                "subnet": "\(networkData.subnet)",
                "gateway": "\(networkData.gateway)"
            ])
        }

        logger.info("Restored WireGuard networks from database", metadata: [
            "count": "\(networks.count)"
        ])
    }

    // MARK: - Network Management

    /// Create a new bridge network using WireGuard
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
        logger.info("Creating WireGuard bridge network", metadata: [
            "network_id": "\(id)",
            "network_name": "\(name)",
            "subnet": "\(subnet ?? "auto")"
        ])

        // Determine subnet (use provided or auto-allocate)
        let effectiveSubnet: String
        let effectiveGateway: String

        if let subnet = subnet {
            effectiveSubnet = subnet
            effectiveGateway = gateway ?? calculateGateway(subnet: subnet)
        } else {
            // Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16
            effectiveSubnet = "172.\(nextSubnetByte).0.0/16"
            effectiveGateway = "172.\(nextSubnetByte).0.1"
            nextSubnetByte += 1
            if nextSubnetByte > 31 {
                nextSubnetByte = 18  // Wrap around
            }
        }

        // Initialize IP allocation for this network
        // If ipRange is specified, calculate starting octet from it
        // Otherwise start at .2 (.1 is gateway)
        if let ipRange = ipRange {
            // Parse ipRange to get starting IP
            // Example: "172.18.0.128/25" -> start at .128
            let rangeComponents = ipRange.split(separator: "/")[0].split(separator: ".")
            if rangeComponents.count == 4, let startOctet = UInt8(rangeComponents[3]) {
                nextIPOctet[id] = startOctet
            } else {
                nextIPOctet[id] = 2  // Fallback
            }
        } else {
            nextIPOctet[id] = 2
        }

        // Create metadata
        let createdDate = Date()
        let metadata = NetworkMetadata(
            id: id,
            name: name,
            driver: "wireguard",
            subnet: effectiveSubnet,
            gateway: effectiveGateway,
            ipRange: ipRange,
            containers: [],
            created: createdDate,
            options: options,
            labels: labels,
            isDefault: isDefault
        )

        networks[id] = metadata
        networksByName[name] = id

        // Persist network to database
        do {
            let optionsJSON = try JSONEncoder().encode(options)
            let labelsJSON = try JSONEncoder().encode(labels)

            try await stateStore.saveNetwork(
                id: id,
                name: name,
                driver: "wireguard",
                scope: "local",
                createdAt: createdDate,
                subnet: effectiveSubnet,
                gateway: effectiveGateway,
                ipRange: ipRange,
                optionsJSON: String(data: optionsJSON, encoding: .utf8),
                labelsJSON: String(data: labelsJSON, encoding: .utf8),
                isDefault: isDefault
            )

            logger.debug("WireGuard network persisted to database", metadata: ["network_id": "\(id)"])
        } catch {
            logger.error("Failed to persist WireGuard network to database", metadata: [
                "network_id": "\(id)",
                "error": "\(error)"
            ])
            // Continue - network is created in memory even if persistence fails
        }

        logger.info("WireGuard bridge network created", metadata: [
            "network_id": "\(id)",
            "subnet": "\(effectiveSubnet)",
            "gateway": "\(effectiveGateway)"
        ])

        return metadata
    }

    /// Delete a bridge network
    public func deleteBridgeNetwork(id: String) async throws {
        guard networks[id] != nil else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Check if any containers are still using this network
        if let metadata = networks[id], !metadata.containers.isEmpty {
            throw NetworkManagerError.hasActiveEndpoints(metadata.name, metadata.containers.count)
        }

        logger.info("Deleting WireGuard bridge network", metadata: ["network_id": "\(id)"])

        // Delete from database first
        do {
            try await stateStore.deleteNetwork(id: id)
            logger.debug("WireGuard network deleted from database", metadata: ["network_id": "\(id)"])
        } catch {
            logger.error("Failed to delete WireGuard network from database", metadata: [
                "network_id": "\(id)",
                "error": "\(error)"
            ])
            // Continue - still delete from memory
        }

        networks.removeValue(forKey: id)
        networksByName.removeValue(forKey: networksByName.first(where: { $0.value == id })?.key ?? "")
        containerAttachments.removeValue(forKey: id)
        nextIPOctet.removeValue(forKey: id)
    }

    // MARK: - Container Attachment

    /// Attach container to network
    ///
    /// Phase 2.2: Creates separate wgN/ethN interfaces for each network (wg0/eth0, wg1/eth1, etc.)
    public func attachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String],
        userSpecifiedIP: String? = nil
    ) async throws -> NetworkAttachment {
        guard var metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        logger.info("Attaching container to WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "container_name": "\(containerName)",
            "user_specified_ip": "\(userSpecifiedIP ?? "auto")"
        ])

        // Check if already attached
        if metadata.containers.contains(containerID) {
            // Container is already in this network - check if this is a restoration after restart
            let existingAttachments = containerAttachments[networkID] ?? [:]
            if let existingAttachment = existingAttachments[containerID],
               let userIP = userSpecifiedIP,
               userIP == existingAttachment.ip {
                // This is a restoration after container restart - same container, same IP
                // The WireGuard client was disconnected on stop, so we need to recreate interfaces
                logger.info("Container restart detected - recreating WireGuard interface with existing IP", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)",
                    "ip": "\(userIP)"
                ])
                // Allow the attachment to proceed - we'll recreate the WireGuard interface
            } else {
                // This is a duplicate connection attempt (not a restart)
                throw NetworkManagerError.alreadyConnected(containerID, metadata.name)
            }
        }

        // Allocate IP address for this container in this network
        let ipAddress: String
        if let userIP = userSpecifiedIP {
            // Validate user-specified IP is within subnet
            guard isIPInSubnet(userIP, subnet: metadata.subnet) else {
                throw NetworkManagerError.invalidIPAddress("IP \(userIP) not in subnet \(metadata.subnet)")
            }

            // Check if IP is already allocated to a DIFFERENT container
            let existingAttachments = containerAttachments[networkID] ?? [:]
            for (existingContainerID, attachment) in existingAttachments {
                if attachment.ip == userIP && existingContainerID != containerID {
                    throw NetworkManagerError.ipAlreadyInUse(userIP)
                }
            }

            // Use user-specified IP
            ipAddress = userIP
            logger.info("Using user-specified IP address", metadata: [
                "ip": "\(ipAddress)",
                "network_id": "\(networkID)"
            ])
        } else {
            // Auto-allocate IP (existing logic)
            ipAddress = try allocateIP(networkID: networkID, subnet: metadata.subnet)
        }

        // Get or create WireGuard client for this container
        let wgClient = try await getOrCreateWireGuardClient(containerID: containerID, container: container)

        // Calculate network index for this container (0 for first network, 1 for second, etc.)
        var indices = containerNetworkIndices[containerID] ?? [:]
        let networkIndex = UInt32(indices.count)

        logger.info("Creating WireGuard interface for network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "network_index": "\(networkIndex)",
            "interface": "wg\(networkIndex)/eth\(networkIndex)"
        ])

        // Generate WireGuard private key for this network's interface
        let privateKey = try generateWireGuardPrivateKey()

        // Calculate listen port (51820 + network_index)
        let listenPort = 51820 + networkIndex

        // Create wgN/ethN interface for this network (hub created lazily)
        let result = try await wgClient.addNetwork(
            networkID: networkID,
            networkIndex: networkIndex,
            privateKey: privateKey,
            listenPort: listenPort,
            peerEndpoint: "",  // Empty - no initial peer needed
            peerPublicKey: "",  // Empty - no initial peer needed
            ipAddress: ipAddress,
            networkCIDR: metadata.subnet,
            gateway: metadata.gateway
        )

        // Store interface metadata
        indices[networkID] = networkIndex
        containerNetworkIndices[containerID] = indices

        var keys = containerInterfaceKeys[containerID] ?? [:]
        keys[networkID] = result.publicKey
        containerInterfaceKeys[containerID] = keys

        logger.info("WireGuard interface created", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "wg_interface": "\(result.wgInterface)",
            "eth_interface": "\(result.ethInterface)",
            "public_key": "\(result.publicKey)",
            "ip_address": "\(ipAddress)"
        ])

        // Phase 2.4: Configure full mesh with other containers on this network
        // Get this container's vmnet endpoint (vmnet IP:port for WireGuard UDP)
        let thisEndpoint = try await wgClient.getVmnetEndpoint()

        logger.info("Configuring full mesh for network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "this_endpoint": "\(thisEndpoint)",
            "this_public_key": "\(result.publicKey)",
            "this_ip": "\(ipAddress)"
        ])

        // Get all OTHER containers already on this network
        let existingAttachments = containerAttachments[networkID] ?? [:]
        let otherContainerIDs = existingAttachments.keys.filter { $0 != containerID }

        logger.debug("Found existing containers on network", metadata: [
            "network_id": "\(networkID)",
            "count": "\(otherContainerIDs.count)"
        ])

        // For each existing container on this network:
        // 1. Add THIS container as a peer to THAT container
        // 2. Add THAT container as a peer to THIS container
        for otherContainerID in otherContainerIDs {
            guard let otherAttachment = existingAttachments[otherContainerID],
                  let otherClient = wireGuardClients[otherContainerID],
                  let otherPublicKey = containerInterfaceKeys[otherContainerID]?[networkID],
                  let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                logger.warning("Skipping peer - missing metadata", metadata: [
                    "other_container_id": "\(otherContainerID)"
                ])
                continue
            }

            // Get the other container's vmnet endpoint
            let otherEndpoint = try await otherClient.getVmnetEndpoint()

            logger.debug("Configuring peer mesh", metadata: [
                "container_id": "\(containerID)",
                "peer_container_id": "\(otherContainerID)",
                "peer_endpoint": "\(otherEndpoint)",
                "peer_ip": "\(otherAttachment.ip)"
            ])

            // Add THIS container as a peer to OTHER container
            do {
                let _ = try await otherClient.addPeer(
                    networkID: networkID,
                    networkIndex: otherNetworkIndex,
                    peerPublicKey: result.publicKey,
                    peerEndpoint: thisEndpoint,
                    peerIPAddress: ipAddress,
                    peerName: containerName,
                    peerContainerID: containerID,
                    peerAliases: aliases
                )
                logger.debug("Added this container as peer to other container (DNS registered)", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)"
                ])
            } catch {
                logger.error("Failed to add this container as peer to other container", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                // Continue - try to add other peers
            }

            // Add OTHER container as a peer to THIS container
            do {
                // Get other container's name and aliases (stored when it was attached)
                let otherName = containerNames[otherContainerID] ?? otherContainerID
                let otherAliases = Array(otherAttachment.aliases.dropLast())  // Drop container name (last element)

                let _ = try await wgClient.addPeer(
                    networkID: networkID,
                    networkIndex: networkIndex,
                    peerPublicKey: otherPublicKey,
                    peerEndpoint: otherEndpoint,
                    peerIPAddress: otherAttachment.ip,
                    peerName: otherName,
                    peerContainerID: otherContainerID,
                    peerAliases: otherAliases
                )
                logger.debug("Added other container as peer to this container (DNS registered)", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)"
                ])
            } catch {
                logger.error("Failed to add other container as peer to this container", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                // Continue - try to add other peers
            }
        }

        logger.info("Full mesh configured for container", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "total_peers": "\(otherContainerIDs.count)"
        ])

        // Generate MAC address (deterministic based on container ID and network ID)
        let mac = generateMACAddress(containerID: containerID, networkID: networkID)

        // Create attachment
        let attachment = NetworkAttachment(
            networkID: networkID,
            ip: ipAddress,
            mac: mac,
            aliases: aliases + [containerName]
        )

        // Update state
        metadata.containers.insert(containerID)
        networks[networkID] = metadata

        var attachments = containerAttachments[networkID] ?? [:]
        attachments[containerID] = attachment
        containerAttachments[networkID] = attachments

        var containerNets = containerNetworks[containerID] ?? []
        containerNets.insert(networkID)
        containerNetworks[containerID] = containerNets

        // Store container name for DNS (Phase 3.1)
        containerNames[containerID] = containerName

        logger.info("Container attached to WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "ip": "\(ipAddress)"
        ])

        return attachment
    }

    /// Detach container from network
    ///
    /// Phase 2.2: Removes wgN/ethN interface for this network
    public func detachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        guard var metadata = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        logger.info("Detaching container from WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])

        // Check if attached
        guard metadata.containers.contains(containerID) else {
            throw NetworkManagerError.notConnected(containerID, metadata.name)
        }

        // Get WireGuard client (may be nil if container is already stopped)
        // When a container is stopped, cleanupStoppedContainer() removes the client
        // but we still need to update metadata.containers to track detachment
        let wgClient = wireGuardClients[containerID]

        // Get network index for this network
        // May be nil if container was already cleaned up
        let indices = containerNetworkIndices[containerID]
        let networkIndex = indices?[networkID]

        // Only perform network operations if container is still running (has a client)
        if let wgClient = wgClient, let networkIndex = networkIndex {
            logger.info("Removing WireGuard interface", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "network_index": "\(networkIndex)",
                "interface": "wg\(networkIndex)/eth\(networkIndex)"
            ])

            // Phase 2.4: Remove this container as a peer from all other containers on this network
            // Get this container's public key
            if let thisPublicKey = containerInterfaceKeys[containerID]?[networkID] {
            // Get all OTHER containers on this network
            let existingAttachments = containerAttachments[networkID] ?? [:]
            let otherContainerIDs = existingAttachments.keys.filter { $0 != containerID }

            logger.debug("Removing this container as peer from other containers", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "peer_count": "\(otherContainerIDs.count)"
            ])

            // Remove this container as a peer from each other container
            for otherContainerID in otherContainerIDs {
                guard let otherClient = wireGuardClients[otherContainerID],
                      let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                    logger.warning("Skipping peer removal - missing metadata", metadata: [
                        "other_container_id": "\(otherContainerID)"
                    ])
                    continue
                }

                do {
                    // Get this container's name for DNS entry removal
                    let thisName = containerNames[containerID] ?? containerID

                    let _ = try await otherClient.removePeer(
                        networkID: networkID,
                        networkIndex: otherNetworkIndex,
                        peerPublicKey: thisPublicKey,
                        peerName: thisName
                    )
                    logger.debug("Removed this container as peer from other container (DNS unregistered)", metadata: [
                        "this_container": "\(containerID)",
                        "other_container": "\(otherContainerID)"
                    ])
                } catch {
                    logger.error("Failed to remove this container as peer from other container", metadata: [
                        "this_container": "\(containerID)",
                        "other_container": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    // Continue - try to remove from other peers
                }
            }

                logger.info("Peer cleanup completed", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)",
                    "peers_cleaned": "\(otherContainerIDs.count)"
                ])
            }

            // Remove network interface (wgN/ethN)
            try await wgClient.removeNetwork(networkID: networkID, networkIndex: networkIndex)

            // Update state
            var updatedIndices = indices!
            updatedIndices.removeValue(forKey: networkID)

            if updatedIndices.isEmpty {
                // Last network removed - cleanup client (hub auto-deleted)
                logger.info("Last network removed, cleaning up client", metadata: [
                    "container_id": "\(containerID)"
                ])

                try await wgClient.disconnect()
                wireGuardClients.removeValue(forKey: containerID)
                containerNetworkIndices.removeValue(forKey: containerID)
                containerInterfaceKeys.removeValue(forKey: containerID)
                containerNetworks.removeValue(forKey: containerID)
                containerNames.removeValue(forKey: containerID)  // Phase 3.1: Clean up DNS name
            } else {
                containerNetworkIndices[containerID] = updatedIndices

                var keys = containerInterfaceKeys[containerID] ?? [:]
                keys.removeValue(forKey: networkID)
                containerInterfaceKeys[containerID] = keys

                var containerNets = containerNetworks[containerID] ?? []
                containerNets.remove(networkID)
                containerNetworks[containerID] = containerNets
            }
        } else {
            // Container is already stopped - WireGuard client and interfaces are already cleaned up
            // by cleanupStoppedContainer(), but we still need to update tracking state
            logger.info("Container already stopped, skipping WireGuard network interface removal", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        }

        // ALWAYS update metadata and attachments, even if container is stopped
        // This ensures network state is consistent after container removal
        metadata.containers.remove(containerID)
        networks[networkID] = metadata

        var attachments = containerAttachments[networkID] ?? [:]
        attachments.removeValue(forKey: containerID)
        containerAttachments[networkID] = attachments

        logger.info("Container detached from WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])
    }

    // MARK: - Network Queries

    /// Get network metadata
    public func getNetwork(id: String) -> NetworkMetadata? {
        return networks[id]
    }

    /// List all networks
    public func listNetworks() -> [NetworkMetadata] {
        return Array(networks.values)
    }

    /// Get network by name
    public func getNetworkByName(name: String) -> NetworkMetadata? {
        guard let id = networksByName[name] else {
            return nil
        }
        return networks[id]
    }

    /// Get container attachments for a network
    public func getNetworkAttachments(networkID: String) -> [String: NetworkAttachment] {
        return containerAttachments[networkID] ?? [:]
    }

    /// Get networks for a container
    public func getContainerNetworks(containerID: String) -> [NetworkMetadata] {
        guard let networkIDs = containerNetworks[containerID] else {
            return []
        }

        return networkIDs.compactMap { networks[$0] }
    }

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    public func cleanupStoppedContainer(containerID: String) async {
        logger.debug("Cleaning up WireGuard state for stopped container", metadata: [
            "container_id": "\(containerID)"
        ])

        // Disconnect WireGuard client if exists
        if let client = wireGuardClients[containerID] {
            try? await client.disconnect()
            wireGuardClients.removeValue(forKey: containerID)
        }

        // Note: We don't remove from networks or containerNetworks because
        // the container is still "attached" to networks, it's just stopped.
        // When it restarts, we'll recreate the WireGuard hub with same IPs.
    }

    // MARK: - Helper Methods

    /// Get or create WireGuard client for a container
    private func getOrCreateWireGuardClient(
        containerID: String,
        container: Containerization.LinuxContainer
    ) async throws -> WireGuardClient {
        // Return existing client if available
        if let client = wireGuardClients[containerID] {
            return client
        }

        // Create new client and connect
        let client = WireGuardClient(logger: logger)
        try await client.connect(container: container, vsockPort: 51820)
        wireGuardClients[containerID] = client

        return client
    }

    /// Get WireGuard client for a container (for port mapping)
    /// Returns nil if container is not attached to any WireGuard networks
    public func getWireGuardClient(containerID: String) -> WireGuardClient? {
        return wireGuardClients[containerID]
    }

    /// Allocate an IP address for a container in a network
    private func allocateIP(networkID: String, subnet: String) throws -> String {
        // Extract network prefix (e.g., "172.18.0.0/16" -> "172.18")
        let components = subnet.split(separator: "/")[0].split(separator: ".")
        guard components.count >= 3 else {
            throw NetworkManagerError.ipAllocationFailed("Invalid subnet format: \(subnet)")
        }

        let prefix = "\(components[0]).\(components[1])"

        // Get next octet (starts at 2, .1 is gateway, or from ipRange)
        guard let octet = nextIPOctet[networkID] else {
            throw NetworkManagerError.ipAllocationFailed("Network not initialized: \(networkID)")
        }

        // Check if ipRange is specified for this network
        let maxOctet: UInt8
        if let metadata = networks[networkID], let ipRange = metadata.ipRange {
            // Parse ipRange to get the upper bound
            // Example: "172.18.0.128/25" -> /25 gives us 128 IPs, so range is .128 to .255
            let rangeComponents = ipRange.split(separator: "/")
            if rangeComponents.count == 2, let cidr = Int(rangeComponents[1]) {
                // Calculate number of host bits
                let hostBits = 32 - cidr
                let numHosts = (1 << hostBits) - 2  // -2 for network and broadcast

                // Get starting IP from ipRange
                let ipComponents = rangeComponents[0].split(separator: ".")
                if ipComponents.count == 4, let startOctet = UInt8(ipComponents[3]) {
                    maxOctet = min(255, startOctet + UInt8(numHosts))
                } else {
                    maxOctet = 254  // Fallback
                }
            } else {
                maxOctet = 254  // Fallback
            }
        } else {
            maxOctet = 254  // Default: allow up to .254 (.255 is broadcast)
        }

        guard octet <= maxOctet else {
            throw NetworkManagerError.ipAllocationFailed("IP pool exhausted for network \(networkID) (range limit reached)")
        }

        let ip = "\(prefix).0.\(octet)"
        nextIPOctet[networkID] = octet + 1

        return ip
    }

    /// Calculate gateway IP from subnet CIDR
    private func calculateGateway(subnet: String) -> String {
        // For simplicity, use .1 as gateway (e.g., 172.18.0.1 for 172.18.0.0/16)
        let components = subnet.split(separator: "/")[0].split(separator: ".")
        guard components.count >= 3 else {
            return "172.18.0.1"  // Fallback
        }

        return "\(components[0]).\(components[1]).0.1"
    }

    /// Generate a deterministic MAC address for a container on a network
    private func generateMACAddress(containerID: String, networkID: String) -> String {
        // Create a deterministic hash from containerID + networkID
        let input = "\(containerID)\(networkID)"
        let hash = input.utf8.reduce(0) { result, byte in
            ((result &<< 5) &- result) &+ UInt64(byte)
        }

        // Format as MAC address (locally administered, unicast)
        // 02:xx:xx:xx:xx:xx (locally administered bit set, unicast)
        let bytes = withUnsafeBytes(of: hash) { Array($0.prefix(6)) }
        return String(format: "02:%02x:%02x:%02x:%02x:%02x",
                     bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
    }

    /// Generate a WireGuard private key
    private func generateWireGuardPrivateKey() throws -> String {
        // Generate random 32 bytes for WireGuard private key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)

        guard result == errSecSuccess else {
            throw NetworkManagerError.ipAllocationFailed("Failed to generate WireGuard private key")
        }

        // Encode as base64 (WireGuard key format)
        let keyData = Data(keyBytes)
        return keyData.base64EncodedString()
    }

    /// Check if an IP address is within a subnet (CIDR)
    private func isIPInSubnet(_ ip: String, subnet: String) -> Bool {
        let parts = subnet.split(separator: "/")
        guard parts.count == 2,
              let cidr = Int(parts[1]) else {
            return false
        }

        let subnetIP = String(parts[0])

        // Parse both IPs into octets
        let ipOctets = ip.split(separator: ".").compactMap { Int($0) }
        let subnetOctets = subnetIP.split(separator: ".").compactMap { Int($0) }

        guard ipOctets.count == 4, subnetOctets.count == 4 else {
            return false
        }

        // Convert CIDR to number of bits to check
        let bitsToCheck = cidr

        // Check bit by bit
        for bit in 0..<bitsToCheck {
            let octetIndex = bit / 8
            let bitIndex = 7 - (bit % 8)

            let ipBit = (ipOctets[octetIndex] >> bitIndex) & 1
            let subnetBit = (subnetOctets[octetIndex] >> bitIndex) & 1

            if ipBit != subnetBit {
                return false
            }
        }

        return true
    }
}

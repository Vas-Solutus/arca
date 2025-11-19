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
    private let getContainer: (String) async throws -> Containerization.LinuxContainer

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

    // Container names for DNS resolution (Phase 3.1): containerID -> containerName
    private var containerNames: [String: String] = [:]

    // Subnet allocation tracking (simple counter for auto-allocation)
    private var nextSubnetByte: UInt8 = 18  // Start at 172.18.0.0/16

    public init(
        logger: Logger,
        stateStore: StateStore,
        getContainer: @escaping (String) async throws -> Containerization.LinuxContainer
    ) {
        self.logger = logger
        self.stateStore = stateStore
        self.getContainer = getContainer
    }

    /// Restore networks from database on daemon startup
    /// This populates the in-memory networks dictionary with persisted network metadata
    public func restoreNetworks() async throws {
        // Restore nextSubnetByte from database (CRITICAL for preventing subnet overlaps after restart)
        let persistedSubnetByte = try await stateStore.getNextSubnetByte()
        nextSubnetByte = UInt8(persistedSubnetByte)

        logger.debug("Restored subnet allocation state", metadata: [
            "next_subnet_byte": "\(nextSubnetByte)"
        ])

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
            // Calculate gateway if not provided or if empty string provided
            // Docker CLI sends empty string "" when no gateway is specified
            effectiveGateway = (gateway?.isEmpty == false) ? gateway! : calculateGateway(subnet: subnet)
        } else {
            // Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16
            // Get allocated subnets from database to detect conflicts
            let allocatedBytes = try await stateStore.getAllocatedSubnetBytes()

            // Find next available subnet byte that's not in use
            var candidateByte = nextSubnetByte
            var attempts = 0
            while allocatedBytes.contains(candidateByte) && attempts < 14 {
                candidateByte += 1
                if candidateByte > 31 {
                    candidateByte = 18  // Wrap around
                }
                attempts += 1
            }

            // Check if we exhausted all subnets
            if allocatedBytes.contains(candidateByte) {
                throw NetworkManagerError.noAvailableSubnets
            }

            effectiveSubnet = "172.\(candidateByte).0.0/16"
            effectiveGateway = "172.\(candidateByte).0.1"

            // Update and persist next subnet byte
            nextSubnetByte = candidateByte + 1
            if nextSubnetByte > 31 {
                nextSubnetByte = 18  // Wrap around
            }

            // Persist the updated nextSubnetByte to database
            try await stateStore.updateNextSubnetByte(Int(nextSubnetByte))

            logger.debug("Auto-allocated subnet", metadata: [
                "allocated_subnet": "172.\(candidateByte).0.0/16",
                "next_subnet_byte": "\(nextSubnetByte)"
            ])
        }

        // NOTE: We no longer use nextIPOctet counter for IP allocation
        // Instead, allocateIP() queries allocated IPs from network_attachments table
        // and finds first available IP, enabling automatic IP reclamation

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
        // Check if user specified an IP (and it's not empty string)
        // Docker CLI/API can send empty string "" when no IP is specified
        if let userIP = userSpecifiedIP, !userIP.isEmpty {
            // Validate user-specified IP is within subnet
            guard isIPInSubnet(userIP, subnet: metadata.subnet) else {
                throw NetworkManagerError.invalidIPAddress("IP \(userIP) not in subnet \(metadata.subnet)")
            }

            // Check if IP is already allocated (query database for accurate check)
            // This catches IPs allocated to containers even if they're not currently running
            let allocatedIPs = try await stateStore.getAllocatedIPs(networkID: networkID)
            if allocatedIPs.contains(userIP) {
                // IP is already in use - check if it's the same container (reconnecting)
                // Get all network attachments from database to find which container has this IP
                let allAttachments = try await stateStore.loadNetworkAttachments(containerID: containerID)
                let existingAttachment = allAttachments.first(where: { $0.networkID == networkID && $0.ipAddress == userIP })

                // If attachment exists and IP matches, this is a reconnect - allow it
                // Otherwise, IP is used by a different container - reject
                if existingAttachment == nil {
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
            // Auto-allocate IP (empty string or nil means auto-allocate)
            ipAddress = try await allocateIP(networkID: networkID, subnet: metadata.subnet)
        }

        // Create WireGuard client for this container
        let wgClient = WireGuardClient(logger: logger)
        try await wgClient.connect(container: container, vsockPort: 51820)

        // Ensure we disconnect when done
        defer {
            Task {
                try? await wgClient.disconnect()
            }
        }

        // Determine network index for this container
        // On restart, reuse existing index to keep eth0 as eth0, eth1 as eth1, etc.
        // For new networks, calculate next available index
        var indices = containerNetworkIndices[containerID] ?? [:]
        let networkIndex: UInt32
        if let existingIndex = indices[networkID] {
            // Restart scenario - reuse existing index
            networkIndex = existingIndex
            logger.debug("Reusing existing network index for restart", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "network_index": "\(networkIndex)"
            ])
        } else {
            // New network attachment - calculate next available index
            networkIndex = UInt32(indices.count)
        }

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
                  let otherPublicKey = containerInterfaceKeys[otherContainerID]?[networkID],
                  let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                logger.warning("Skipping peer - missing metadata", metadata: [
                    "other_container_id": "\(otherContainerID)"
                ])
                continue
            }

            // Create WireGuard client for peer container
            let otherContainer: Containerization.LinuxContainer
            do {
                otherContainer = try await getContainer(otherContainerID)
            } catch {
                logger.error("Failed to get peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

            let otherClient = WireGuardClient(logger: logger)
            do {
                try await otherClient.connect(container: otherContainer, vsockPort: 51820)
            } catch {
                logger.error("Failed to connect to peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

            // Ensure we disconnect when done
            defer {
                Task {
                    try? await otherClient.disconnect()
                }
            }

            // Get the other container's vmnet endpoint
            let otherEndpoint: String
            do {
                otherEndpoint = try await otherClient.getVmnetEndpoint()
            } catch {
                logger.error("Failed to get vmnet endpoint from peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

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

        // Get network index for this network
        let indices = containerNetworkIndices[containerID]
        let networkIndex = indices?[networkID]

        // Try to create WireGuard client for the target container
        // If we can't connect, we'll still clean up peer relationships on OTHER containers
        var targetClient: WireGuardClient?
        if let container = try? await getContainer(containerID) {
            let client = WireGuardClient(logger: logger)
            if (try? await client.connect(container: container, vsockPort: 51820)) != nil {
                targetClient = client
            }
        }

        // Ensure we disconnect the target client when done
        if let client = targetClient {
            defer {
                Task {
                    try? await client.disconnect()
                }
            }
        }

        if targetClient == nil {
            logger.warning("Cannot connect to target container - will skip interface removal but still clean up peers", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        }

        // ALWAYS try to remove this container as a peer from other containers
        // This ensures mesh consistency even if target container is unreachable
        if let networkIndex = networkIndex,
           let thisPublicKey = containerInterfaceKeys[containerID]?[networkID] {

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
                guard let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                    logger.warning("Skipping peer removal - missing metadata", metadata: [
                        "other_container_id": "\(otherContainerID)"
                    ])
                    continue
                }

                // Get peer container
                let otherContainer: Containerization.LinuxContainer
                do {
                    otherContainer = try await getContainer(otherContainerID)
                } catch {
                    logger.error("Failed to get peer container for removal", metadata: [
                        "peer_container_id": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    continue
                }

                // Create WireGuard client for peer
                let otherClient = WireGuardClient(logger: logger)
                do {
                    try await otherClient.connect(container: otherContainer, vsockPort: 51820)
                } catch {
                    logger.error("Failed to connect to peer for removal", metadata: [
                        "peer_container_id": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    continue
                }

                // Ensure we disconnect when done
                defer {
                    Task {
                        try? await otherClient.disconnect()
                    }
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

            // Remove network interface (wgN/ethN) from target container if we have a client
            if let targetClient = targetClient {
                logger.info("Removing WireGuard interface from target container", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)",
                    "network_index": "\(networkIndex)",
                    "interface": "wg\(networkIndex)/eth\(networkIndex)"
                ])
                try await targetClient.removeNetwork(networkID: networkID, networkIndex: networkIndex)
            } else {
                logger.warning("Cannot remove interface from unreachable target container", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)"
                ])
            }

            // Update state
            var updatedIndices = indices!
            updatedIndices.removeValue(forKey: networkID)

            if updatedIndices.isEmpty {
                // Last network removed - cleanup state (client cleanup in defer block, hub auto-deleted)
                logger.info("Last network removed, cleaning up state", metadata: [
                    "container_id": "\(containerID)"
                ])

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
            // Container has no network index - already cleaned up or never had this network
            logger.info("Container has no network index, skipping WireGuard operations", metadata: [
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

        // Note: We don't cache WireGuard clients, so nothing to clean up here.
        // The container is still "attached" to networks metadata-wise, just stopped.
        // When it restarts, we'll recreate the WireGuard hub with same IPs.
    }

    // MARK: - Helper Methods


    /// Allocate an IP address for a container in a network
    /// Uses smart IP reclamation - finds first available IP by querying allocated IPs from database
    private func allocateIP(networkID: String, subnet: String) async throws -> String {
        // Extract network prefix (e.g., "172.18.0.0/16" -> "172.18")
        let components = subnet.split(separator: "/")[0].split(separator: ".")
        guard components.count >= 3 else {
            throw NetworkManagerError.ipAllocationFailed("Invalid subnet format: \(subnet)")
        }

        let prefix = "\(components[0]).\(components[1])"

        // Parse CIDR to get subnet mask
        let cidrComponents = subnet.split(separator: "/")
        guard cidrComponents.count == 2, let cidr = Int(cidrComponents[1]) else {
            throw NetworkManagerError.ipAllocationFailed("Invalid subnet format: \(subnet)")
        }

        // Calculate broadcast address based on CIDR
        // For /30: 4 IPs total (2^(32-30) = 4)
        // For /24: 256 IPs total (2^(32-24) = 256)
        let hostBits = 32 - cidr
        let totalIPs = 1 << hostBits  // 2^hostBits

        // Calculate max usable IP (exclude network address and broadcast)
        // For /30 (4 IPs): .0 (network), .1 (gateway), .2 (usable), .3 (broadcast) -> max = 2
        // For /24 (256 IPs): .0 (network), .1 (gateway), .2-.254 (usable), .255 (broadcast) -> max = 254
        let broadcastOctet = UInt8(totalIPs - 1)

        // Determine IP allocation range
        var minOctet: UInt8 = 2  // .1 is gateway, start at .2
        var maxOctet: UInt8 = broadcastOctet - 1  // Exclude broadcast address

        // Check if ipRange is specified for this network
        if let metadata = networks[networkID], let ipRange = metadata.ipRange {
            // Parse ipRange to get the bounds
            // Example: "172.18.0.128/25" -> allocate from .128 to .255
            let rangeComponents = ipRange.split(separator: "/")
            if rangeComponents.count == 2, let cidr = Int(rangeComponents[1]) {
                // Calculate number of host bits
                let hostBits = 32 - cidr
                let numHosts = (1 << hostBits) - 2  // -2 for network and broadcast

                // Get starting IP from ipRange
                let ipComponents = rangeComponents[0].split(separator: ".")
                if ipComponents.count == 4, let startOctet = UInt8(ipComponents[3]) {
                    minOctet = startOctet  // Start from the specified IP
                    maxOctet = min(254, startOctet + UInt8(numHosts))
                }
            }
        }

        // Get all currently allocated IPs from database (network_attachments table)
        // This automatically reflects freed IPs when containers are removed (CASCADE DELETE)
        let allocatedIPs = try await stateStore.getAllocatedIPs(networkID: networkID)

        // Find first available IP by scanning from minOctet to maxOctet
        for octet in minOctet...maxOctet {
            let candidateIP = "\(prefix).0.\(octet)"

            // Skip if already allocated
            if allocatedIPs.contains(candidateIP) {
                continue
            }

            // Found an available IP!
            logger.debug("Allocated IP (reclaimed if previously used)", metadata: [
                "network_id": "\(networkID)",
                "ip": "\(candidateIP)",
                "total_allocated": "\(allocatedIPs.count)"
            ])

            return candidateIP
        }

        // No available IPs in range
        throw NetworkManagerError.ipAllocationFailed(
            "IP pool exhausted for network \(networkID): all IPs from \(prefix).0.\(minOctet) to \(prefix).0.\(maxOctet) are allocated"
        )
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

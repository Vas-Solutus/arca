import Foundation
import Logging
import Containerization

/// vmnet backend for Docker bridge networks
///
/// Provides high-performance native Apple networking using vmnet.framework.
/// Each Docker network gets its own VmnetNetwork instance for true network isolation.
///
/// **Limitations:**
/// - No dynamic network attachment (containers must specify --network at creation)
/// - No port mapping support
/// - Containers can only join ONE network
/// - No overlay networks
///
/// **Advantages:**
/// - Lowest latency (~0.5ms, native kernel switching)
/// - No helper VM required
/// - Native kernel-level switching
public actor VmnetNetworkBackend {
    private let logger: Logger
    private var networks: [String: SharedVmnetNetwork] = [:]  // networkID -> vmnet
    private var networkMetadata: [String: NetworkMetadata] = [:]  // networkID -> metadata

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Network Management

    /// Create a new bridge network using vmnet
    public func createBridgeNetwork(
        id: String,
        name: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) throws -> NetworkMetadata {
        logger.info("Creating vmnet bridge network", metadata: [
            "network_id": "\(id)",
            "network_name": "\(name)",
            "subnet": "\(subnet ?? "auto")"
        ])

        // Determine subnet (use provided or auto-allocate)
        let effectiveSubnet: String
        if let subnet = subnet {
            effectiveSubnet = subnet
        } else {
            // Auto-allocate from 10.0.0.0/8 space to avoid collisions
            effectiveSubnet = try allocateSubnet()
        }

        // Create VmnetNetwork for this bridge
        let vmnet = try SharedVmnetNetwork(subnet: effectiveSubnet)
        networks[id] = vmnet

        // Create metadata
        let metadata = NetworkMetadata(
            id: id,
            name: name,
            driver: "vmnet",
            subnet: vmnet.subnet,
            gateway: vmnet.gateway,
            ipRange: ipRange,  // vmnet doesn't use ipRange for allocation, but store for API compatibility
            containers: [],
            created: Date(),
            options: options,
            labels: labels,
            isDefault: isDefault
        )
        networkMetadata[id] = metadata

        logger.info("vmnet bridge network created", metadata: [
            "network_id": "\(id)",
            "subnet": "\(vmnet.subnet)",
            "gateway": "\(vmnet.gateway)"
        ])

        return metadata
    }

    /// Delete a bridge network
    public func deleteBridgeNetwork(id: String) throws {
        guard networks[id] != nil else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Check if any containers are still using this network
        if let metadata = networkMetadata[id], !metadata.containers.isEmpty {
            throw NetworkManagerError.hasActiveEndpoints(metadata.name, metadata.containers.count)
        }

        logger.info("Deleting vmnet bridge network", metadata: ["network_id": "\(id)"])

        networks.removeValue(forKey: id)
        networkMetadata.removeValue(forKey: id)
    }

    // MARK: - Container Attachment

    /// Get vmnet interface for container (called during container creation)
    ///
    /// **IMPORTANT**: This must be called BEFORE container.start()
    /// vmnet interfaces must be configured in VZVirtualMachineConfiguration
    /// which is immutable after VM starts.
    public func getInterfaceForContainer(containerID: String, networkID: String) throws -> any Containerization.Interface {
        guard let vmnet = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        guard let interface = try vmnet.createInterface(containerID) else {
            throw NetworkManagerError.ipAllocationFailed("Failed to create vmnet interface for container \(containerID) on network \(networkID)")
        }

        logger.info("Allocated vmnet interface for container", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "ip": "\(interface.address)"
        ])

        // Update metadata
        if var metadata = networkMetadata[networkID] {
            metadata.containers.insert(containerID)
            networkMetadata[networkID] = metadata
        }

        return interface
    }

    /// Detach container from network (called during container removal)
    public func detachContainer(containerID: String, networkID: String) throws {
        guard let vmnet = networks[networkID] else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        try vmnet.releaseInterface(containerID)

        logger.info("Released vmnet interface for container", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])

        // Update metadata
        if var metadata = networkMetadata[networkID] {
            metadata.containers.remove(containerID)
            networkMetadata[networkID] = metadata
        }
    }

    /// Attempt to dynamically attach container to network (NOT SUPPORTED)
    ///
    /// vmnet backend does not support dynamic network attachment because
    /// VZVirtualMachineConfiguration is immutable after vm.start().
    ///
    /// Throws NetworkManagerError.dynamicAttachNotSupported with helpful error message.
    public func attachContainer(containerID: String, networkID: String, ipAddress: String, gateway: String) throws {
        throw NetworkManagerError.dynamicAttachNotSupported(
            backend: "vmnet",
            suggestion: "Recreate container with --network flag at 'docker run' time, or use WireGuard backend (bridge networks) for full Docker Network API support"
        )
    }

    // MARK: - Network Queries

    /// Get network metadata
    public func getNetwork(id: String) -> NetworkMetadata? {
        return networkMetadata[id]
    }

    /// List all networks
    public func listNetworks() -> [NetworkMetadata] {
        return Array(networkMetadata.values)
    }

    /// Get network by name
    public func getNetworkByName(name: String) -> NetworkMetadata? {
        return networkMetadata.values.first { $0.name == name }
    }

    /// Get container attachments for a network
    public func getNetworkAttachments(networkID: String) -> [String: NetworkAttachment] {
        // vmnet backend doesn't store detailed attachment info
        // Return empty for now - could be enhanced if needed
        return [:]
    }

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    /// vmnet backend doesn't need to do anything as containers are attached at creation time
    public func cleanupStoppedContainer(containerID: String) {
        // No-op for vmnet backend - no dynamic state to clean up
        // Containers are attached at creation time and cleaned up automatically
    }

    // MARK: - Subnet Allocation

    private var nextSubnetIndex: Int = 0

    /// Allocate a unique subnet from 10.0.0.0/8 space
    /// Uses /24 subnets: 10.0.N.0/24 where N increments
    ///
    /// **Reserved Subnets:**
    /// - 172.17.0.0/16 - Default bridge network (WireGuard backend)
    /// - 192.168.67.0/24 - Default vmnet network
    /// - 10.x.x.x - User-created vmnet networks (auto-allocated)
    private func allocateSubnet() throws -> String {
        guard nextSubnetIndex < 255 else {
            throw NetworkManagerError.ipAllocationFailed("Subnet pool exhausted (255 /24 networks allocated)")
        }

        let subnet = "10.0.\(nextSubnetIndex).0/24"
        nextSubnetIndex += 1
        return subnet
    }
}

// NetworkMetadata is defined in NetworkTypes.swift

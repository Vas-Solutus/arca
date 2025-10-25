import Foundation
import Logging
import Containerization
import ContainerizationOS

/// VLAN-based network provider for Docker bridge networks.
/// Uses VLANs for network isolation with native vmnet performance (5-10x faster than TAP).
///
/// Architecture:
/// - Helper VM creates VLAN interfaces (e.g., eth0.100) and acts as router/gateway
/// - Container VMs create matching VLAN interfaces and configure IPs
/// - All traffic flows via native vmnet with VLAN tagging
/// - Helper VM provides NAT, DNS (dnsmasq), and port forwarding (iptables DNAT)
///
/// This provider is used for Docker bridge driver networks.
/// For overlay networks, use the OVS/OVN provider instead.
public actor VLANNetworkProvider {
    private let logger: Logger
    private var helperVM: NetworkHelperVM?
    private var routerClient: RouterClient?
    private var vlanAllocator: VLANIDAllocator

    // Track network attachments: containerID -> networkID -> attachment
    private var attachments: [String: [String: VLANAttachment]] = [:]

    // Track VLAN assignments: networkID -> VLAN ID
    private var networkVLANs: [String: UInt32] = [:]

    struct VLANAttachment {
        let networkID: String
        let vlanID: UInt32
        let device: String          // eth0, eth1, etc.
        let ipAddress: String       // Container IP in CIDR notation (e.g., "172.18.0.2/16")
        let gateway: String
        let interfaceName: String   // VLAN interface name (e.g., "eth0.100")
    }

    public enum VLANProviderError: Error, CustomStringConvertible {
        case helperVMNotRunning
        case routerClientNotConnected
        case containerNotFound
        case networkNotFound
        case vlanAllocationFailed
        case attachmentFailed(String)
        case detachmentFailed(String)
        case invalidCIDR(String)

        public var description: String {
            switch self {
            case .helperVMNotRunning: return "Helper VM not running"
            case .routerClientNotConnected: return "Router client not connected"
            case .containerNotFound: return "Container not found"
            case .networkNotFound: return "Network not found"
            case .vlanAllocationFailed: return "Failed to allocate VLAN ID"
            case .attachmentFailed(let msg): return "Failed to attach VLAN network: \(msg)"
            case .detachmentFailed(let msg): return "Failed to detach VLAN network: \(msg)"
            case .invalidCIDR(let cidr): return "Invalid CIDR notation: \(cidr)"
            }
        }
    }

    public init(logger: Logger) {
        self.logger = logger
        // VLAN IDs 100-4094 available (1-99 reserved, 4095 reserved)
        self.vlanAllocator = VLANIDAllocator(startID: 100, endID: 4094)
    }

    /// Set the helper VM reference and connect router client
    public func setHelperVM(_ helperVM: NetworkHelperVM) async throws {
        self.helperVM = helperVM

        // Create and connect router client
        guard let container = await helperVM.getContainer() else {
            throw VLANProviderError.helperVMNotRunning
        }

        let client = RouterClient(logger: logger)
        try await client.connect(container: container, vsockPort: 50052)
        self.routerClient = client

        logger.info("VLAN network provider initialized and connected to router service")
    }

    // MARK: - Network Creation

    /// Create a VLAN network in the helper VM.
    ///
    /// - Parameters:
    ///   - networkID: Docker network ID
    ///   - networkName: Docker network name
    ///   - subnet: Network subnet in CIDR notation (e.g., "172.18.0.0/16")
    ///   - gateway: Gateway IP address (e.g., "172.18.0.1")
    ///
    /// - Throws: VLANProviderError if network creation fails
    public func createNetwork(
        networkID: String,
        networkName: String,
        subnet: String,
        gateway: String
    ) async throws {
        guard let routerClient = routerClient else {
            throw VLANProviderError.routerClientNotConnected
        }

        // Allocate VLAN ID for this network
        guard let vlanID = vlanAllocator.allocate() else {
            throw VLANProviderError.vlanAllocationFailed
        }

        logger.info("Creating VLAN network", metadata: [
            "network_id": "\(networkID)",
            "network_name": "\(networkName)",
            "vlan_id": "\(vlanID)",
            "subnet": "\(subnet)",
            "gateway": "\(gateway)"
        ])

        do {
            // Create VLAN interface in helper VM
            let interfaceName = try await routerClient.createVLAN(
                vlanID: vlanID,
                subnet: subnet,
                gateway: gateway,
                networkName: networkName,
                enableNAT: true
            )

            // Track VLAN assignment
            networkVLANs[networkID] = vlanID

            logger.info("VLAN network created successfully", metadata: [
                "network_id": "\(networkID)",
                "vlan_id": "\(vlanID)",
                "interface": "\(interfaceName)"
            ])
        } catch {
            // Free VLAN ID on failure
            vlanAllocator.free(vlanID)
            throw VLANProviderError.attachmentFailed("Failed to create VLAN in helper VM: \(error)")
        }
    }

    /// Delete a VLAN network from the helper VM.
    ///
    /// - Parameter networkID: Docker network ID
    /// - Throws: VLANProviderError if network deletion fails
    public func deleteNetwork(networkID: String) async throws {
        guard let routerClient = routerClient else {
            throw VLANProviderError.routerClientNotConnected
        }

        guard let vlanID = networkVLANs[networkID] else {
            throw VLANProviderError.networkNotFound
        }

        logger.info("Deleting VLAN network", metadata: [
            "network_id": "\(networkID)",
            "vlan_id": "\(vlanID)"
        ])

        do {
            // Delete VLAN interface from helper VM
            try await routerClient.deleteVLAN(vlanID: vlanID)

            // Free VLAN ID and remove tracking
            vlanAllocator.free(vlanID)
            networkVLANs.removeValue(forKey: networkID)

            logger.info("VLAN network deleted successfully", metadata: [
                "network_id": "\(networkID)",
                "vlan_id": "\(vlanID)"
            ])
        } catch {
            throw VLANProviderError.detachmentFailed("Failed to delete VLAN from helper VM: \(error)")
        }
    }

    // MARK: - Container Attachment

    /// Attach a container to a VLAN network.
    ///
    /// - Parameters:
    ///   - container: Container to attach
    ///   - containerID: Docker container ID
    ///   - networkID: Network ID to attach to
    ///   - ipAddress: IP address for the container (e.g., "172.18.0.2")
    ///   - gateway: Gateway IP address (e.g., "172.18.0.1")
    ///   - device: Network device name in container (e.g., "eth0")
    ///   - subnet: Network subnet in CIDR notation (for calculating netmask)
    ///
    /// - Throws: VLANProviderError if attachment fails
    public func attachContainer(
        container: LinuxContainer,
        containerID: String,
        networkID: String,
        ipAddress: String,
        gateway: String,
        device: String,
        subnet: String
    ) async throws {
        guard let vlanID = networkVLANs[networkID] else {
            throw VLANProviderError.networkNotFound
        }

        // Calculate CIDR notation from IP and subnet
        guard let prefixLength = extractPrefixLength(from: subnet) else {
            throw VLANProviderError.invalidCIDR(subnet)
        }
        let ipCIDR = "\(ipAddress)/\(prefixLength)"

        logger.info("Attaching container to VLAN network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "vlan_id": "\(vlanID)",
            "ip": "\(ipCIDR)",
            "device": "\(device)"
        ])

        // Connect to container's VLAN service
        let configClient = NetworkConfigClient(logger: logger)
        try await configClient.connect(container: container, vsockPort: 50051)

        defer {
            Task {
                try? await configClient.disconnect()
            }
        }

        do {
            // Create VLAN interface in container VM
            // Parent interface is always "en0" (the vmnet interface)
            let interfaceName = try await configClient.createVLAN(
                parentInterface: "en0",
                vlanID: vlanID,
                ipAddress: ipCIDR,
                gateway: gateway
            )

            // Track attachment
            var containerAttachments = attachments[containerID] ?? [:]
            containerAttachments[networkID] = VLANAttachment(
                networkID: networkID,
                vlanID: vlanID,
                device: device,
                ipAddress: ipCIDR,
                gateway: gateway,
                interfaceName: interfaceName
            )
            attachments[containerID] = containerAttachments

            logger.info("Container attached to VLAN network successfully", metadata: [
                "container_id": "\(containerID)",
                "vlan_id": "\(vlanID)",
                "interface": "\(interfaceName)"
            ])
        } catch {
            throw VLANProviderError.attachmentFailed("Failed to create VLAN in container: \(error)")
        }
    }

    /// Detach a container from a VLAN network.
    ///
    /// - Parameters:
    ///   - container: Container to detach
    ///   - containerID: Docker container ID
    ///   - networkID: Network ID to detach from
    ///
    /// - Throws: VLANProviderError if detachment fails
    public func detachContainer(
        container: LinuxContainer,
        containerID: String,
        networkID: String
    ) async throws {
        guard let containerAttachments = attachments[containerID],
              let attachment = containerAttachments[networkID] else {
            logger.warning("Container not attached to network", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
            return
        }

        logger.info("Detaching container from VLAN network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "vlan_id": "\(attachment.vlanID)"
        ])

        // Connect to container's VLAN service
        let configClient = NetworkConfigClient(logger: logger)
        try await configClient.connect(container: container, vsockPort: 50051)

        defer {
            Task {
                try? await configClient.disconnect()
            }
        }

        do {
            // Delete VLAN interface from container VM
            try await configClient.deleteVLAN(interfaceName: attachment.interfaceName)

            // Remove attachment tracking
            var updatedAttachments = attachments[containerID] ?? [:]
            updatedAttachments.removeValue(forKey: networkID)
            if updatedAttachments.isEmpty {
                attachments.removeValue(forKey: containerID)
            } else {
                attachments[containerID] = updatedAttachments
            }

            logger.info("Container detached from VLAN network successfully", metadata: [
                "container_id": "\(containerID)",
                "vlan_id": "\(attachment.vlanID)"
            ])
        } catch {
            throw VLANProviderError.detachmentFailed("Failed to delete VLAN from container: \(error)")
        }
    }

    /// Cleanup all attachments for a container (called when container is removed).
    ///
    /// - Parameter containerID: Docker container ID
    public func cleanupContainer(containerID: String) {
        if let containerAttachments = attachments.removeValue(forKey: containerID) {
            logger.info("Cleaned up VLAN attachments for container", metadata: [
                "container_id": "\(containerID)",
                "attachment_count": "\(containerAttachments.count)"
            ])
        }
    }

    // MARK: - Helper Methods

    /// Extract prefix length from subnet CIDR notation (e.g., "172.18.0.0/16" -> 16)
    private func extractPrefixLength(from subnet: String) -> Int? {
        let parts = subnet.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else {
            return nil
        }
        return prefix
    }
}

/// Allocates and tracks VLAN IDs for network isolation.
/// Thread-safe via value semantics.
struct VLANIDAllocator {
    private var availableIDs: Set<UInt32>
    private var allocatedIDs: Set<UInt32> = []

    init(startID: UInt32, endID: UInt32) {
        self.availableIDs = Set(startID...endID)
    }

    mutating func allocate() -> UInt32? {
        guard let id = availableIDs.first else {
            return nil
        }
        availableIDs.remove(id)
        allocatedIDs.insert(id)
        return id
    }

    mutating func free(_ id: UInt32) {
        if allocatedIDs.remove(id) != nil {
            availableIDs.insert(id)
        }
    }

    func isAllocated(_ id: UInt32) -> Bool {
        return allocatedIDs.contains(id)
    }
}

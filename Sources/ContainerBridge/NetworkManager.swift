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

    // Backends (initialized based on config)
    private var ovsBackend: OVSNetworkBackend?
    private var vmnetBackend: VmnetNetworkBackend?

    // Dependencies for OVS backend
    private let helperVM: NetworkHelperVM?
    private let networkBridge: NetworkBridge?

    /// Initialize NetworkManager with configuration
    public init(
        config: ArcaConfig,
        stateStore: StateStore,
        helperVM: NetworkHelperVM?,
        networkBridge: NetworkBridge?,
        logger: Logger
    ) {
        self.config = config
        self.stateStore = stateStore
        self.helperVM = helperVM
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
            // Initialize OVS backend (requires helper VM)
            guard let helperVM = helperVM,
                  let networkBridge = networkBridge else {
                throw NetworkManagerError.helperVMNotReady
            }

            let backend = OVSNetworkBackend(
                stateStore: stateStore,
                helperVM: helperVM,
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
        }

        logger.info("NetworkManager initialized successfully")
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
            return metadata.id

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
            return metadata.id
        }
    }

    /// Delete a network
    public func deleteNetwork(id: String) async throws {
        // Try both backends (network could be in either)
        if let backend = ovsBackend, await backend.getNetwork(id: id) != nil {
            try await backend.deleteNetwork(id: id)
            return
        }

        if let backend = vmnetBackend, await backend.getNetwork(id: id) != nil {
            try await backend.deleteBridgeNetwork(id: id)
            return
        }

        throw NetworkManagerError.networkNotFound(id)
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
        // Find which backend has this network
        if let backend = ovsBackend, await backend.getNetwork(id: networkID) != nil {
            return try await backend.attachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID,
                containerName: containerName,
                aliases: aliases
            )
        }

        if let backend = vmnetBackend, await backend.getNetwork(id: networkID) != nil {
            // vmnet backend doesn't support dynamic attach
            try await backend.attachContainer(
                containerID: containerID,
                networkID: networkID,
                ipAddress: "",  // Not used (will throw error)
                gateway: ""     // Not used (will throw error)
            )
            // Should never reach here (attachContainer throws)
            fatalError("vmnet backend should have thrown dynamicAttachNotSupported")
        }

        throw NetworkManagerError.networkNotFound(networkID)
    }

    /// Detach container from network
    public func detachContainerFromNetwork(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        // Find which backend has this network
        if let backend = ovsBackend, await backend.getNetwork(id: networkID) != nil {
            try await backend.detachContainer(
                containerID: containerID,
                container: container,
                networkID: networkID
            )
            return
        }

        if let backend = vmnetBackend, await backend.getNetwork(id: networkID) != nil {
            try await backend.detachContainer(containerID: containerID, networkID: networkID)
            return
        }

        throw NetworkManagerError.networkNotFound(networkID)
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
        // Try OVS backend first
        if let backend = ovsBackend, let network = await backend.getNetwork(id: id) {
            return network
        }

        // Try vmnet backend
        if let backend = vmnetBackend, let network = await backend.getNetwork(id: id) {
            return network
        }

        return nil
    }

    /// Get network by name
    public func getNetworkByName(name: String) async -> NetworkMetadata? {
        // Try OVS backend first
        if let backend = ovsBackend, let network = await backend.getNetworkByName(name: name) {
            return network
        }

        // Try vmnet backend
        if let backend = vmnetBackend, let network = await backend.getNetworkByName(name: name) {
            return network
        }

        return nil
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

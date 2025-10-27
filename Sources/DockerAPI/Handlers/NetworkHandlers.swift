import Foundation
import Logging
import ContainerBridge
import NIOHTTP1

// Helper extension for converting arrays to tuples
extension Array where Element == String {
    func tuple() -> (String, String)? {
        guard count >= 2 else { return nil }
        return (self[0], self[1])
    }
}

/// Handlers for Docker Engine API network endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct NetworkHandlers: Sendable {
    private let networkManager: NetworkManager
    private let containerManager: ContainerManager
    private let logger: Logger

    public init(networkManager: NetworkManager, containerManager: ContainerManager, logger: Logger) {
        self.networkManager = networkManager
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Get error description from Swift errors
    private func errorDescription(_ error: Error) -> String {
        return error.localizedDescription
    }

    /// Handle GET /networks
    /// Lists all networks
    ///
    /// Query parameters:
    /// - filters: JSON encoded filters (name, id, driver, type, label)
    public func handleListNetworks(filters: [String: [String]] = [:]) async -> Result<[Network], NetworkError> {
        logger.debug("Handling list networks request", metadata: [
            "filters": "\(filters)"
        ])

        do {
            let allNetworks = await networkManager.listNetworks()

            // Apply filters
            let filteredMetadata = applyFilters(allNetworks, filters: filters)

            // Convert to Docker API format
            var networks: [Network] = []
            for metadata in filteredMetadata {
                networks.append(await convertToDockerNetwork(metadata))
            }

            logger.info("Listed networks", metadata: ["count": "\(networks.count)"])
            return .success(networks)
        } catch let error as NetworkManagerError {
            logger.error("Failed to list networks", metadata: ["error": "\(error)"])
            return .failure(NetworkError.listFailed(error.description))
        } catch {
            logger.error("Unexpected error listing networks", metadata: ["error": "\(error)"])
            return .failure(NetworkError.listFailed(errorDescription(error)))
        }
    }

    /// Handle GET /networks/{id}
    /// Inspects a network
    public func handleInspectNetwork(id: String) async -> Result<Network, NetworkError> {
        logger.debug("Handling inspect network request", metadata: ["id": "\(id)"])

        do {
            // Try resolving as name or ID
            let resolvedID = await networkManager.resolveNetworkID(id) ?? id

            guard let metadata = await networkManager.getNetwork(id: resolvedID) else {
                return .failure(NetworkError.notFound(id))
            }
            let network = await convertToDockerNetwork(metadata)

            logger.info("Inspected network", metadata: [
                "id": "\(network.id)",
                "name": "\(network.name)"
            ])
            return .success(network)
        } catch let error as NetworkManagerError {
            logger.error("Failed to inspect network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(id))
            default:
                return .failure(NetworkError.inspectFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error inspecting network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.inspectFailed(errorDescription(error)))
        }
    }

    /// Handle POST /networks/create
    /// Creates a new network
    public func handleCreateNetwork(request: NetworkCreateRequest) async -> Result<NetworkCreateResponse, NetworkError> {
        logger.info("Handling create network request", metadata: [
            "name": "\(request.name)",
            "driver": "\(request.driver ?? "bridge")"
        ])

        // Extract IPAM configuration
        let subnet = request.ipam?.config?.first?.subnet
        let gateway = request.ipam?.config?.first?.gateway
        let ipRange = request.ipam?.config?.first?.ipRange

        do {
            let networkID = try await networkManager.createNetwork(
                name: request.name,
                driver: request.driver ?? "bridge",
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: request.options ?? [:],
                labels: request.labels ?? [:]
            )

            logger.info("Network created successfully", metadata: [
                "id": "\(networkID)",
                "name": "\(request.name)"
            ])

            return .success(NetworkCreateResponse(id: networkID))
        } catch let error as NetworkManagerError {
            logger.error("Failed to create network", metadata: [
                "name": "\(request.name)",
                "error": "\(error)"
            ])

            switch error {
            case .nameExists:
                return .failure(NetworkError.conflict(error.description))
            case .unsupportedDriver:
                return .failure(NetworkError.invalidRequest(error.description))
            default:
                return .failure(NetworkError.createFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error creating network", metadata: [
                "name": "\(request.name)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.createFailed(errorDescription(error)))
        }
    }

    /// Handle DELETE /networks/{id}
    /// Deletes a network
    public func handleDeleteNetwork(id: String, force: Bool = false) async -> Result<Void, NetworkError> {
        logger.info("Handling delete network request", metadata: [
            "id": "\(id)",
            "force": "\(force)"
        ])

        do {
            // Resolve network name or ID to full network ID
            guard let resolvedID = await networkManager.resolveNetworkID(id) else {
                return .failure(NetworkError.notFound(id))
            }

            try await networkManager.deleteNetwork(id: resolvedID)

            logger.info("Network deleted successfully", metadata: ["id": "\(id)"])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to delete network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(id))
            case .hasActiveEndpoints, .cannotDeleteDefault:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.deleteFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error deleting network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.deleteFailed(errorDescription(error)))
        }
    }

    /// Handle POST /networks/{id}/connect
    /// Connects a container to a network
    public func handleConnectNetwork(
        networkID: String,
        containerID: String,
        containerName: String,
        endpointConfig: EndpointConfig?
    ) async -> Result<Void, NetworkError> {
        logger.info("Handling connect network request", metadata: [
            "network": "\(networkID)",
            "container": "\(containerID)"
        ])

        // Extract IPv4 address and aliases from endpoint config
        let ipv4Address = endpointConfig?.ipamConfig?.ipv4Address
        let aliases = endpointConfig?.aliases ?? []

        do {
            // Resolve network name or ID to full network ID
            guard let resolvedNetworkID = await networkManager.resolveNetworkID(networkID) else {
                return .failure(NetworkError.notFound("network \(networkID) not found"))
            }

            // Get the container object
            guard let container = try await containerManager.getLinuxContainer(dockerID: containerID) else {
                return .failure(NetworkError.notFound("Container \(containerID) not found"))
            }

            // Get container name for DNS
            let containerName = await containerManager.getContainerName(dockerID: containerID) ?? String(containerID.prefix(12))

            // Attach to network via NetworkManager (OVS attachment)
            let attachment = try await networkManager.attachContainerToNetwork(
                containerID: containerID,
                container: container,
                networkID: resolvedNetworkID,
                containerName: containerName,
                aliases: aliases
            )

            // Record the attachment in ContainerManager (triggers DNS push)
            try await containerManager.attachContainerToNetwork(
                dockerID: containerID,
                networkID: resolvedNetworkID,
                ip: attachment.ip,
                mac: attachment.mac,
                aliases: attachment.aliases
            )

            logger.info("Container connected to network successfully", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)"
            ])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to connect container to network", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(networkID))
            case .alreadyConnected:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.connectFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error connecting container", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.connectFailed(errorDescription(error)))
        }
    }

    /// Handle POST /networks/{id}/disconnect
    /// Disconnects a container from a network
    public func handleDisconnectNetwork(
        networkID: String,
        containerID: String,
        force: Bool = false
    ) async -> Result<Void, NetworkError> {
        logger.info("Handling disconnect network request", metadata: [
            "network": "\(networkID)",
            "container": "\(containerID)",
            "force": "\(force)"
        ])

        do {
            // Get the container object
            guard let container = try await containerManager.getLinuxContainer(dockerID: containerID) else {
                return .failure(NetworkError.notFound("Container \(containerID) not found"))
            }

            try await networkManager.detachContainerFromNetwork(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

            logger.info("Container disconnected from network successfully", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)"
            ])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to disconnect container from network", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(networkID))
            case .notConnected:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.disconnectFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error disconnecting container", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.disconnectFailed(errorDescription(error)))
        }
    }

    // MARK: - Helper Methods

    /// Apply filters to network list
    private func applyFilters(_ networks: [NetworkMetadata], filters: [String: [String]]) -> [NetworkMetadata] {
        var filtered = networks

        // Filter by name
        if let names = filters["name"], !names.isEmpty {
            filtered = filtered.filter { network in
                names.contains(network.name)
            }
        }

        // Filter by ID
        if let ids = filters["id"], !ids.isEmpty {
            filtered = filtered.filter { network in
                ids.contains(where: { network.id.hasPrefix($0) })
            }
        }

        // Filter by driver
        if let drivers = filters["driver"], !drivers.isEmpty {
            filtered = filtered.filter { network in
                drivers.contains(network.driver)
            }
        }

        // Filter by label
        if let labels = filters["label"], !labels.isEmpty {
            filtered = filtered.filter { network in
                labels.allSatisfy { labelFilter in
                    if let (key, value) = labelFilter.split(separator: "=", maxSplits: 1).map({ String($0) }).tuple() {
                        return network.labels[key] == value
                    } else {
                        return network.labels[labelFilter] != nil
                    }
                }
            }
        }

        return filtered
    }

    /// Convert NetworkMetadata to Docker API Network format
    private func convertToDockerNetwork(_ metadata: NetworkMetadata) async -> Network {
        // Format created timestamp as ISO8601
        let iso8601Formatter = ISO8601DateFormatter()
        let createdString = iso8601Formatter.string(from: metadata.created)

        // Create IPAM config
        let ipamConfig = IPAMConfig(
            subnet: metadata.subnet,
            gateway: metadata.gateway
        )
        let ipam = IPAM(driver: "default", config: [ipamConfig])

        // Get container attachments for this network
        let attachments = await networkManager.getNetworkAttachments(networkID: metadata.id)
        var containers: [String: NetworkContainer] = [:]

        for (containerID, attachment) in attachments {
            // Get container name
            let containerName = await containerManager.getContainerName(dockerID: containerID) ?? containerID

            containers[containerID] = NetworkContainer(
                name: containerName,
                endpointID: containerID,  // Use container ID as endpoint ID
                macAddress: attachment.mac,
                ipv4Address: "\(attachment.ip)/\(metadata.subnet.split(separator: "/").last ?? "16")",
                ipv6Address: ""  // IPv6 not supported yet
            )
        }

        return Network(
            name: metadata.name,
            id: metadata.id,
            created: createdString,
            scope: "local",
            driver: metadata.driver,
            enableIPv6: false,
            ipam: ipam,
            internal: false,
            attachable: false,
            ingress: false,
            containers: containers,
            options: metadata.options,
            labels: metadata.labels
        )
    }
}

// MARK: - Network Errors

public enum NetworkError: Error, CustomStringConvertible {
    case notFound(String)
    case conflict(String)
    case invalidRequest(String)
    case listFailed(String)
    case inspectFailed(String)
    case createFailed(String)
    case deleteFailed(String)
    case connectFailed(String)
    case disconnectFailed(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "network \(id) not found"
        case .conflict(let message):
            return message
        case .invalidRequest(let message):
            return message
        case .listFailed(let message):
            return "failed to list networks: \(message)"
        case .inspectFailed(let message):
            return "failed to inspect network: \(message)"
        case .createFailed(let message):
            return "failed to create network: \(message)"
        case .deleteFailed(let message):
            return "failed to delete network: \(message)"
        case .connectFailed(let message):
            return "failed to connect container to network: \(message)"
        case .disconnectFailed(let message):
            return "failed to disconnect container from network: \(message)"
        }
    }
}

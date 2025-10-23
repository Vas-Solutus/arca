import Foundation
import Logging
import ContainerBridge
import NIOHTTP1

/// Handlers for Docker Engine API network endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct NetworkHandlers: Sendable {
    private let networkManager: NetworkManager
    private let logger: Logger

    public init(networkManager: NetworkManager, logger: Logger) {
        self.networkManager = networkManager
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
            let networkMetadataList = try await networkManager.listNetworks(filters: filters)

            // Convert to Docker API format
            let networks = networkMetadataList.map { metadata in
                convertToDockerNetwork(metadata)
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
            let metadata = try await networkManager.inspectNetwork(id: id)
            let network = convertToDockerNetwork(metadata)

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
        } catch let error as IPAMError {
            logger.error("IPAM error creating network", metadata: [
                "name": "\(request.name)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.createFailed(error.description))
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
            try await networkManager.deleteNetwork(id: id, force: force)

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
            _ = try await networkManager.connectContainer(
                containerID: containerID,
                containerName: containerName,
                networkID: networkID,
                ipv4Address: ipv4Address,
                aliases: aliases
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
        } catch let error as IPAMError {
            logger.error("IPAM error connecting container", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.connectFailed(error.description))
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
            try await networkManager.disconnectContainer(
                containerID: containerID,
                networkID: networkID,
                force: force
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

    /// Convert NetworkMetadata to Docker API Network format
    private func convertToDockerNetwork(_ metadata: NetworkManager.NetworkMetadata) -> Network {
        // Format created timestamp as ISO8601
        let iso8601Formatter = ISO8601DateFormatter()
        let createdString = iso8601Formatter.string(from: metadata.created)

        // Create IPAM config
        let ipamConfig = IPAMConfig(
            subnet: metadata.subnet,
            gateway: metadata.gateway
        )
        let ipam = IPAM(driver: "default", config: [ipamConfig])

        // Convert containers map (currently empty - will be populated when containers are attached)
        let containers: [String: NetworkContainer] = [:]

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

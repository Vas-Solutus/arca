import Foundation
import Logging
import ContainerBridge

/// Handlers for Docker Engine API container endpoints
/// Reference: Documentation/DockerEngineAPIv1.51.yaml
public struct ContainerHandlers {
    private let containerManager: ContainerManager
    private let logger: Logger

    public init(containerManager: ContainerManager, logger: Logger) {
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Handle GET /containers/json
    /// Lists all containers
    ///
    /// Query parameters:
    /// - all: Show all containers (default shows just running)
    /// - limit: Limit the number of results
    /// - size: Return container size information
    /// - filters: JSON encoded filters
    public func handleListContainers(all: Bool = false, limit: Int? = nil, size: Bool = false, filters: [String: String] = [:]) async -> ContainerListResponse {
        logger.debug("Handling list containers request", metadata: [
            "all": "\(all)",
            "limit": "\(limit?.description ?? "none")",
            "size": "\(size)",
            "filters": "\(filters)"
        ])

        do {
            // Get containers from ContainerManager
            var containers = try await containerManager.listContainers(all: all, filters: filters)

            // Apply limit if specified
            if let limit = limit, limit > 0 {
                containers = Array(containers.prefix(limit))
            }

            // Convert to Docker API format
            let dockerContainers = containers.map { summary in
                ContainerListItem(
                    id: summary.id,
                    names: summary.names,
                    image: summary.image,
                    imageID: summary.imageID,
                    command: summary.command,
                    created: summary.created,
                    state: summary.state,
                    status: summary.status,
                    ports: summary.ports.map { port in
                        Port(
                            privatePort: port.privatePort,
                            publicPort: port.publicPort,
                            type: port.type,
                            ip: port.ip
                        )
                    },
                    labels: summary.labels,
                    sizeRw: size ? summary.sizeRw : nil,
                    sizeRootFs: size ? summary.sizeRootFs : nil
                )
            }

            logger.info("Listed containers", metadata: [
                "count": "\(dockerContainers.count)"
            ])

            return ContainerListResponse(containers: dockerContainers)
        } catch {
            logger.error("Failed to list containers", metadata: [
                "error": "\(error)"
            ])

            return ContainerListResponse(containers: [], error: error)
        }
    }

    /// Handle POST /containers/create
    /// Creates a new container
    public func handleCreateContainer(request: ContainerCreateRequest, name: String?) async -> Result<ContainerCreateResponse, ContainerError> {
        logger.info("Handling create container request", metadata: [
            "image": "\(request.image)",
            "name": "\(name ?? "auto")"
        ])

        do {
            let containerID = try await containerManager.createContainer(
                image: request.image,
                name: name,
                command: request.cmd,
                env: request.env,
                workingDir: request.workingDir,
                labels: request.labels
            )

            logger.info("Container created", metadata: [
                "id": "\(containerID)"
            ])

            return .success(ContainerCreateResponse(id: containerID))
        } catch {
            logger.error("Failed to create container", metadata: [
                "error": "\(error)"
            ])

            return .failure(ContainerError.creationFailed(error.localizedDescription))
        }
    }

    /// Handle POST /containers/{id}/start
    /// Starts a container
    public func handleStartContainer(id: String) async -> Result<Void, ContainerError> {
        logger.info("Handling start container request", metadata: [
            "id": "\(id)"
        ])

        do {
            try await containerManager.startContainer(id: id)

            logger.info("Container started", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to start container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.startFailed(error.localizedDescription))
        }
    }

    /// Handle POST /containers/{id}/stop
    /// Stops a container
    public func handleStopContainer(id: String, timeout: Int?) async -> Result<Void, ContainerError> {
        logger.info("Handling stop container request", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        do {
            try await containerManager.stopContainer(id: id, timeout: timeout)

            logger.info("Container stopped", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to stop container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.stopFailed(error.localizedDescription))
        }
    }
}

// MARK: - Response Types

/// Response wrapper for list containers
public struct ContainerListResponse {
    public let containers: [ContainerListItem]
    public let error: Error?

    public init(containers: [ContainerListItem], error: Error? = nil) {
        self.containers = containers
        self.error = error
    }
}

// MARK: - Error Types

public enum ContainerError: Error, CustomStringConvertible {
    case creationFailed(String)
    case startFailed(String)
    case stopFailed(String)
    case notFound(String)
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .creationFailed(let msg):
            return "Failed to create container: \(msg)"
        case .startFailed(let msg):
            return "Failed to start container: \(msg)"
        case .stopFailed(let msg):
            return "Failed to stop container: \(msg)"
        case .notFound(let id):
            return "Container not found: \(id)"
        case .invalidRequest(let msg):
            return "Invalid request: \(msg)"
        }
    }
}

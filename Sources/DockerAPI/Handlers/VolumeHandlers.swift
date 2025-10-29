import Foundation
import Logging
import ContainerBridge
import NIOHTTP1

/// Handlers for Docker Engine API volume endpoints
/// Reference: Documentation/DOCKER_ENGINE_v1.51.yaml
public struct VolumeHandlers: Sendable {
    private let volumeManager: VolumeManager
    private let logger: Logger

    public init(volumeManager: VolumeManager, logger: Logger) {
        self.volumeManager = volumeManager
        self.logger = logger
    }

    /// Handle POST /volumes/create
    /// Creates a new volume
    ///
    /// Request body: VolumeCreateRequest
    /// - name: Volume name (optional, auto-generated if not provided)
    /// - driver: Volume driver (default: "local")
    /// - driverOpts: Driver options
    /// - labels: User-defined labels
    public func handleCreateVolume(request: VolumeCreateRequest) async -> Result<Volume, VolumeHandlerError> {
        logger.info("Handling create volume request", metadata: [
            "name": "\(request.name ?? "auto")",
            "driver": "\(request.driver ?? "local")"
        ])

        do {
            let metadata = try await volumeManager.createVolume(
                name: request.name,
                driver: request.driver,
                driverOpts: request.driverOpts,
                labels: request.labels
            )

            let volume = convertToDockerVolume(metadata)

            logger.info("Volume created", metadata: [
                "name": "\(volume.name)",
                "driver": "\(volume.driver)",
                "mountpoint": "\(volume.mountpoint)"
            ])

            return .success(volume)
        } catch let error as VolumeError {
            logger.error("Failed to create volume", metadata: ["error": "\(error)"])
            return .failure(.volumeError(error))
        } catch {
            logger.error("Unexpected error creating volume", metadata: ["error": "\(error)"])
            return .failure(.internalError(error.localizedDescription))
        }
    }

    /// Handle GET /volumes
    /// Lists all volumes
    ///
    /// Query parameters:
    /// - filters: JSON encoded filters (name, label, dangling)
    public func handleListVolumes(filters: [String: [String]] = [:]) async -> Result<VolumeListResponse, VolumeHandlerError> {
        logger.debug("Handling list volumes request", metadata: [
            "filters": "\(filters)"
        ])

        let volumeList = await volumeManager.listVolumes(filters: filters)

        let volumes = volumeList.map { convertToDockerVolume($0) }

        let response = VolumeListResponse(
            volumes: volumes.isEmpty ? nil : volumes,
            warnings: nil
        )

        logger.info("Listed volumes", metadata: ["count": "\(volumes.count)"])
        return .success(response)
    }

    /// Handle GET /volumes/{name}
    /// Inspects a volume
    public func handleInspectVolume(name: String) async -> Result<Volume, VolumeHandlerError> {
        logger.debug("Handling inspect volume request", metadata: ["name": "\(name)"])

        do {
            let metadata = try await volumeManager.inspectVolume(name: name)
            let volume = convertToDockerVolume(metadata)

            logger.info("Inspected volume", metadata: [
                "name": "\(volume.name)",
                "driver": "\(volume.driver)"
            ])

            return .success(volume)
        } catch let error as VolumeError {
            if case .notFound = error {
                logger.warning("Volume not found", metadata: ["name": "\(name)"])
                return .failure(.notFound(name))
            }
            logger.error("Failed to inspect volume", metadata: ["error": "\(error)"])
            return .failure(.volumeError(error))
        } catch {
            logger.error("Unexpected error inspecting volume", metadata: ["error": "\(error)"])
            return .failure(.internalError(error.localizedDescription))
        }
    }

    /// Handle DELETE /volumes/{name}
    /// Deletes a volume
    ///
    /// Query parameters:
    /// - force: Force removal even if in use (default: false)
    public func handleDeleteVolume(name: String, force: Bool = false) async -> Result<Void, VolumeHandlerError> {
        logger.info("Handling delete volume request", metadata: [
            "name": "\(name)",
            "force": "\(force)"
        ])

        do {
            try await volumeManager.deleteVolume(name: name, force: force)

            logger.info("Volume deleted", metadata: ["name": "\(name)"])
            return .success(())
        } catch let error as VolumeError {
            if case .notFound = error {
                logger.warning("Volume not found for deletion", metadata: ["name": "\(name)"])
                return .failure(.notFound(name))
            }
            if case .inUse = error {
                logger.warning("Volume in use, cannot delete", metadata: ["name": "\(name)"])
                return .failure(.inUse(name))
            }
            logger.error("Failed to delete volume", metadata: ["error": "\(error)"])
            return .failure(.volumeError(error))
        } catch {
            logger.error("Unexpected error deleting volume", metadata: ["error": "\(error)"])
            return .failure(.internalError(error.localizedDescription))
        }
    }

    /// Handle POST /volumes/prune
    /// Deletes unused volumes
    ///
    /// Query parameters:
    /// - filters: JSON encoded filters (label, all)
    public func handlePruneVolumes(filters: [String: [String]] = [:]) async -> Result<VolumePruneResponse, VolumeHandlerError> {
        logger.info("Handling prune volumes request", metadata: [
            "filters": "\(filters)"
        ])

        do {
            let (volumesDeleted, spaceReclaimed) = try await volumeManager.pruneVolumes(filters: filters)

            let response = VolumePruneResponse(
                volumesDeleted: volumesDeleted.isEmpty ? nil : volumesDeleted,
                spaceReclaimed: spaceReclaimed
            )

            logger.info("Volumes pruned", metadata: [
                "deletedCount": "\(volumesDeleted.count)",
                "spaceReclaimed": "\(spaceReclaimed)"
            ])

            return .success(response)
        } catch {
            logger.error("Failed to prune volumes", metadata: ["error": "\(error)"])
            return .failure(.internalError(error.localizedDescription))
        }
    }

    // MARK: - Private Helpers

    /// Convert VolumeManager.VolumeMetadata to Docker API Volume
    private func convertToDockerVolume(_ metadata: VolumeManager.VolumeMetadata) -> Volume {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAtString = formatter.string(from: metadata.createdAt)

        return Volume(
            name: metadata.name,
            driver: metadata.driver,
            mountpoint: metadata.mountpoint,
            createdAt: createdAtString,
            status: nil,
            labels: metadata.labels,
            scope: "local",
            options: metadata.options
        )
    }
}

// MARK: - VolumeHandlerError

public enum VolumeHandlerError: Error, CustomStringConvertible {
    case notFound(String)
    case inUse(String)
    case volumeError(VolumeError)
    case internalError(String)

    public var description: String {
        switch self {
        case .notFound(let name):
            return "Volume not found: \(name)"
        case .inUse(let name):
            return "Volume in use: \(name)"
        case .volumeError(let error):
            return error.description
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }

    /// HTTP status code for this error
    public var statusCode: HTTPResponseStatus {
        switch self {
        case .notFound:
            return .notFound
        case .inUse:
            return .conflict
        case .volumeError(let error):
            switch error {
            case .notFound:
                return .notFound
            case .alreadyExists:
                return .conflict
            case .inUse:
                return .conflict
            default:
                return .internalServerError
            }
        case .internalError:
            return .internalServerError
        }
    }
}

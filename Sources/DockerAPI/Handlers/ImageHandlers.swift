import Foundation
import Logging
import ContainerBridge
import ContainerizationExtras
import NIOHTTP1

/// Handlers for Docker Engine API image endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct ImageHandlers: Sendable {
    private let imageManager: ImageManager
    private let logger: Logger

    public init(imageManager: ImageManager, logger: Logger) {
        self.imageManager = imageManager
        self.logger = logger
    }

    /// Get error description for HTTP responses
    private func errorDescription(_ error: Error) -> String {
        return error.localizedDescription
    }

    /// Handle GET /images/json
    /// Lists all images
    ///
    /// Query parameters:
    /// - all: Show all images (default hides intermediate images)
    /// - filters: JSON encoded filters
    /// - digests: Show digest information
    public func handleListImages(
        all: Bool = false,
        filters: [String: [String]] = [:],
        digests: Bool = false
    ) async -> ImageListResponse {
        logger.debug("Handling list images request", metadata: [
            "all": "\(all)",
            "filters": "\(filters)",
            "digests": "\(digests)"
        ])

        do {
            // Get images from ImageManager
            let images = try await imageManager.listImages(filters: filters)

            // Convert to Docker API format
            let dockerImages = images.map { summary in
                ImageListItem(
                    id: summary.id,
                    parentId: summary.parent ?? "",
                    repoTags: summary.repoTags.isEmpty ? nil : summary.repoTags,
                    repoDigests: digests ? summary.repoDigests : nil,
                    created: summary.created,
                    size: summary.size,
                    virtualSize: summary.virtualSize,
                    sharedSize: summary.sharedSize,
                    labels: summary.labels.isEmpty ? nil : summary.labels,
                    containers: summary.containers
                )
            }

            logger.info("Listed images", metadata: [
                "count": "\(dockerImages.count)"
            ])

            return ImageListResponse(images: dockerImages)
        } catch {
            logger.error("Failed to list images", metadata: [
                "error": "\(error)"
            ])

            return ImageListResponse(images: [], error: error)
        }
    }

    /// Handle POST /images/create (non-streaming)
    /// Pulls an image from a registry without progress updates
    ///
    /// Query parameters:
    /// - fromImage: Image name
    /// - tag: Tag (default: latest)
    /// - platform: Platform in format os[/arch[/variant]]
    ///
    /// Headers:
    /// - X-Registry-Auth: Base64 encoded authentication
    public func handlePullImage(
        fromImage: String,
        tag: String? = nil,
        platform: String? = nil,
        auth: RegistryAuthentication? = nil
    ) async -> Result<ImagePullResponse, ImageHandlerError> {
        let imageRef = tag.map { "\(fromImage):\($0)" } ?? fromImage

        logger.info("Handling pull image request", metadata: [
            "image": "\(imageRef)",
            "platform": "\(platform ?? "default")"
        ])

        do {
            let imageDetails = try await imageManager.pullImage(
                reference: imageRef,
                auth: auth
            )

            logger.info("Image pulled successfully", metadata: [
                "id": "\(imageDetails.id)"
            ])

            return .success(ImagePullResponse(
                status: "Pull complete",
                id: imageDetails.id
            ))
        } catch {
            logger.error("Failed to pull image", metadata: [
                "image": "\(imageRef)",
                "error": "\(error)"
            ])

            return .failure(.pullFailed(errorDescription(error)))
        }
    }

    /// Handle POST /images/create (streaming)
    /// Pulls an image with real-time progress updates
    ///
    /// Query parameters:
    /// - fromImage: Image name
    /// - tag: Tag (default: latest)
    /// - platform: Platform in format os[/arch[/variant]]
    ///
    /// Headers:
    /// - X-Registry-Auth: Base64 encoded authentication
    public func handlePullImageStreaming(
        fromImage: String,
        tag: String? = nil,
        platform: String? = nil,
        auth: RegistryAuthentication? = nil
    ) async -> HTTPResponseType {
        let imageRef = tag.map { "\(fromImage):\($0)" } ?? fromImage

        logger.info("Handling streaming pull image request", metadata: [
            "image": "\(imageRef)",
            "platform": "\(platform ?? "default")"
        ])

        // Return streaming response with callback
        return .streaming(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")])
        ) { writer in
            do {
                // First, resolve the manifest to get real layer digests and manifest digest
                self.logger.debug("Resolving manifest for layer digests", metadata: ["image": "\(imageRef)"])
                let (layerDigests, layerSizes, manifestDigest) = try await self.imageManager.resolveManifestLayersWithDigest(
                    reference: imageRef,
                    auth: auth
                )

                self.logger.info("Resolved manifest layers", metadata: [
                    "image": "\(imageRef)",
                    "layer_count": "\(layerDigests.count)",
                    "manifest_digest": "\(manifestDigest.prefix(19))..."
                ])

                // Create progress formatter with real layer digests and sizes
                let formatter = DockerProgressFormatter(
                    logger: self.logger,
                    imageReference: imageRef,
                    layerDigests: layerDigests,
                    layerSizes: layerSizes,
                    manifestDigest: manifestDigest
                )

                // Pull image with progress handler
                let imageDetails = try await self.imageManager.pullImage(
                    reference: imageRef,
                    auth: auth,
                    progress: { events in
                        // Format progress events as Docker JSON
                        let jsonLines = await formatter.formatProgress(events: events)

                        // Write each JSON line to stream (handle errors internally)
                        for jsonLine in jsonLines {
                            self.logger.debug("Writing progress line", metadata: [
                                "json": "\(jsonLine)"
                            ])
                            let data = Data((jsonLine + "\n").utf8)
                            do {
                                try await writer.write(data)
                            } catch {
                                self.logger.error("Failed to write progress", metadata: ["error": "\(error)"])
                            }
                        }
                    }
                )

                // Send final completion message to ensure progress persists
                let completionLine = await formatter.formatCompletion()
                self.logger.debug("Writing completion line", metadata: [
                    "json": "\(completionLine)"
                ])
                let completionData = Data((completionLine + "\n").utf8)
                try await writer.write(completionData)

                // Send digest message
                let digestStatus = [
                    "status": "Digest: \(manifestDigest)"
                ] as [String: Any]

                if let jsonData = try? JSONSerialization.data(withJSONObject: digestStatus, options: []),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let data = Data((jsonString + "\n").utf8)
                    try await writer.write(data)
                }

                // Send final status message
                let finalStatus = [
                    "status": "Status: Downloaded newer image for \(imageRef)"
                ] as [String: Any]

                if let jsonData = try? JSONSerialization.data(withJSONObject: finalStatus, options: []),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let data = Data((jsonString + "\n").utf8)
                    try await writer.write(data)
                }

                self.logger.info("Streaming image pull completed", metadata: [
                    "image": "\(imageRef)",
                    "id": "\(imageDetails.id)"
                ])

            } catch {
                self.logger.error("Failed to pull image", metadata: [
                    "image": "\(imageRef)",
                    "error": "\(error)"
                ])

                // Send error message to stream
                let errorStatus = ["error": errorDescription(error)]
                if let jsonData = try? JSONSerialization.data(withJSONObject: errorStatus, options: []),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let data = Data((jsonString + "\n").utf8)
                    try? await writer.write(data)
                }

                throw error
            }
        }
    }

    /// Handle GET /images/{name}/json
    /// Inspects an image
    public func handleInspectImage(nameOrId: String) async -> Result<ImageInspect, ImageHandlerError> {
        logger.debug("Handling inspect image request", metadata: [
            "name_or_id": "\(nameOrId)"
        ])

        do {
            guard let imageDetails = try await imageManager.inspectImage(nameOrId: nameOrId) else {
                return .failure(.imageNotFound(nameOrId))
            }

            // Convert to Docker API format
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let dockerImage = ImageInspect(
                id: imageDetails.id,
                repoTags: imageDetails.repoTags.isEmpty ? nil : imageDetails.repoTags,
                repoDigests: imageDetails.repoDigests.isEmpty ? nil : imageDetails.repoDigests,
                parent: imageDetails.parent ?? "",
                comment: imageDetails.comment,
                created: formatter.string(from: imageDetails.created),
                container: imageDetails.container,
                containerConfig: mapImageConfig(imageDetails.containerConfig),
                dockerVersion: imageDetails.dockerVersion,
                author: imageDetails.author,
                config: mapImageConfig(imageDetails.config),
                architecture: imageDetails.architecture,
                os: imageDetails.os,
                size: imageDetails.size,
                virtualSize: imageDetails.virtualSize,
                graphDriver: ImageGraphDriver(
                    name: imageDetails.graphDriver.name,
                    data: imageDetails.graphDriver.data
                ),
                rootFS: ImageRootFS(
                    type: imageDetails.rootFS.type,
                    layers: imageDetails.rootFS.layers.isEmpty ? nil : imageDetails.rootFS.layers
                ),
                metadata: ImageMetadataResponse(
                    lastTagTime: imageDetails.metadata.lastTagTime.map { formatter.string(from: $0) }
                )
            )

            logger.info("Image inspected", metadata: [
                "id": "\(imageDetails.id)"
            ])

            return .success(dockerImage)
        } catch {
            logger.error("Failed to inspect image", metadata: [
                "name_or_id": "\(nameOrId)",
                "error": "\(error)"
            ])

            return .failure(.inspectFailed(errorDescription(error)))
        }
    }

    /// Handle DELETE /images/{name}
    /// Deletes an image
    ///
    /// Query parameters:
    /// - force: Force removal
    /// - noprune: Don't delete untagged parents
    public func handleDeleteImage(
        nameOrId: String,
        force: Bool = false,
        noprune: Bool = false
    ) async -> Result<[ImageDeleteResponseItem], ImageHandlerError> {
        logger.info("Handling delete image request", metadata: [
            "name_or_id": "\(nameOrId)",
            "force": "\(force)"
        ])

        do {
            let deleteItems = try await imageManager.deleteImage(
                nameOrId: nameOrId,
                force: force
            )

            // Convert to Docker API format
            let dockerItems = deleteItems.map { item in
                ImageDeleteResponseItem(
                    untagged: item.untagged,
                    deleted: item.deleted
                )
            }

            logger.info("Image deleted", metadata: [
                "name_or_id": "\(nameOrId)",
                "items": "\(dockerItems.count)"
            ])

            return .success(dockerItems)
        } catch let error as ImageManagerError {
            logger.error("Failed to delete image", metadata: [
                "name_or_id": "\(nameOrId)",
                "error": "\(error)"
            ])

            // Map ImageManagerError to ImageHandlerError with proper case
            switch error {
            case .imageNotFound:
                return .failure(.imageNotFound(nameOrId))
            default:
                return .failure(.deleteFailed(error.description))
            }
        } catch {
            logger.error("Failed to delete image", metadata: [
                "name_or_id": "\(nameOrId)",
                "error": "\(error)"
            ])

            return .failure(.deleteFailed(errorDescription(error)))
        }
    }

    // MARK: - Helper Methods

    /// Map ImageContainerConfig to ImageConfig
    private func mapImageConfig(_ config: ImageContainerConfig?) -> ImageConfig? {
        guard let config = config else { return nil }

        return ImageConfig(
            hostname: config.hostname.isEmpty ? nil : config.hostname,
            domainname: config.domainname.isEmpty ? nil : config.domainname,
            user: config.user.isEmpty ? nil : config.user,
            attachStdin: config.attachStdin,
            attachStdout: config.attachStdout,
            attachStderr: config.attachStderr,
            exposedPorts: config.exposedPorts.map { ports in
                Dictionary(uniqueKeysWithValues: ports.map { ($0.key, AnyCodable($0.value)) })
            },
            tty: config.tty,
            openStdin: config.openStdin,
            stdinOnce: config.stdinOnce,
            env: config.env.isEmpty ? nil : config.env,
            cmd: config.cmd.isEmpty ? nil : config.cmd,
            image: config.image,
            volumes: config.volumes.map { volumes in
                Dictionary(uniqueKeysWithValues: volumes.map { ($0.key, AnyCodable($0.value)) })
            },
            workingDir: config.workingDir.isEmpty ? nil : config.workingDir,
            entrypoint: config.entrypoint,
            onBuild: config.onBuild,
            labels: config.labels.isEmpty ? nil : config.labels
        )
    }
}

// MARK: - Response Types

/// Response wrapper for list images
public struct ImageListResponse {
    public let images: [ImageListItem]
    public let error: Error?

    public init(images: [ImageListItem], error: Error? = nil) {
        self.images = images
        self.error = error
    }
}

/// Response for image pull operation
public struct ImagePullResponse: Codable {
    public let status: String
    public let id: String?

    public init(status: String, id: String? = nil) {
        self.status = status
        self.id = id
    }
}

// MARK: - Error Types

public enum ImageHandlerError: Error, CustomStringConvertible {
    case pullFailed(String)
    case inspectFailed(String)
    case deleteFailed(String)
    case imageNotFound(String)
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .pullFailed(let msg):
            return "Failed to pull image: \(msg)"
        case .inspectFailed(let msg):
            return "Failed to inspect image: \(msg)"
        case .deleteFailed(let msg):
            return "Failed to delete image: \(msg)"
        case .imageNotFound(let name):
            return "No such image: \(name)"
        case .invalidRequest(let msg):
            return "Invalid request: \(msg)"
        }
    }
}

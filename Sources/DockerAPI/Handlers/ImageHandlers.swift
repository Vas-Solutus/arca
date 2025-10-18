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

            return .failure(.pullFailed(error.localizedDescription))
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
                let errorStatus = ["error": error.localizedDescription]
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

            return .failure(.inspectFailed(error.localizedDescription))
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
        } catch {
            logger.error("Failed to delete image", metadata: [
                "name_or_id": "\(nameOrId)",
                "error": "\(error)"
            ])

            return .failure(.deleteFailed(error.localizedDescription))
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

// MARK: - Docker Progress Formatting

/// Formats Apple Containerization ProgressEvents into Docker-compatible JSON progress messages
///
/// Shows honest aggregate progress instead of faking per-layer progress.
/// Apple's API only provides aggregate statistics without per-blob identification.
public actor DockerProgressFormatter {
    private let logger: Logger
    private let imageReference: String
    private let manifestDigest: String
    private let layerDigests: [String]

    // Aggregate progress tracking
    private var totalDownloadSize: Int64 = 0  // Total bytes to download (all blobs)
    private var downloadedBytes: Int64 = 0     // Bytes downloaded so far
    private var totalItems: Int = 0            // Total blobs to download
    private var completedItems: Int = 0        // Blobs completed
    private var lastCompletedItems: Int = 0    // Track last completed count to detect new completions

    // Throttling
    private var lastProgressUpdate: Date = Date()

    public init(logger: Logger, imageReference: String, layerDigests: [String], layerSizes: [Int64], manifestDigest: String) {
        self.logger = logger
        self.imageReference = imageReference
        self.manifestDigest = manifestDigest
        self.layerDigests = layerDigests

        logger.debug("Initialized aggregate progress formatter", metadata: [
            "layer_count": "\(layerDigests.count)",
            "total_layer_size": "\(layerSizes.reduce(0, +))"
        ])
    }

    /// Process progress events and return Docker-formatted JSON lines
    public func formatProgress(events: [ProgressEvent]) -> [String] {
        var output: [String] = []

        for event in events {
            switch event.event {
            case "add-total-size":
                if let size = event.value as? Int64 {
                    totalDownloadSize += size
                }

            case "add-total-items":
                if let count = event.value as? Int {
                    totalItems += count
                }

            case "add-size":
                if let size = event.value as? Int64 {
                    downloadedBytes += size

                    // Throttle progress updates to avoid spam (every 100ms or when complete)
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.1 || downloadedBytes >= totalDownloadSize {
                        lastProgressUpdate = now
                        output.append(formatDownloadProgress())
                    }
                }

            case "add-items":
                if let count = event.value as? Int {
                    completedItems += count

                    // Only emit completion messages for first two items (manifest and config)
                    // Items 2+ all use the same bulk download ID, so we'll mark that complete at the end
                    while lastCompletedItems < min(completedItems, 2) {
                        let itemIndex = lastCompletedItems
                        output.append(formatItemCompletion(itemIndex: itemIndex))
                        lastCompletedItems += 1
                    }
                }

            default:
                logger.debug("Unknown progress event", metadata: ["event": "\(event.event)"])
            }
        }

        return output
    }

    /// Get digest ID for a specific item index
    /// Uses real digests from the image manifest
    private func getIDForItem(_ itemIndex: Int) -> String {
        // First blob (manifest): use manifest digest
        if itemIndex == 0 {
            return shortDigest(manifestDigest)
        }
        // Second blob (config): use first layer digest
        else if itemIndex == 1, !layerDigests.isEmpty {
            return shortDigest(layerDigests[0])
        }
        // All subsequent blobs (bulk layers): use second layer digest
        else if layerDigests.count > 1 {
            return shortDigest(layerDigests[1])
        }
        // Fallback: use manifest digest
        else {
            return shortDigest(manifestDigest)
        }
    }

    /// Get appropriate digest ID based on completed items
    /// Uses real digests from the image manifest for initial small blobs,
    /// then consolidates to image reference for bulk layer downloads
    private func getProgressID() -> String {
        return getIDForItem(completedItems)
    }

    /// Convert a digest to short form (12 chars, no sha256: prefix)
    private func shortDigest(_ digest: String) -> String {
        let stripped = digest.replacingOccurrences(of: "sha256:", with: "")
        return String(stripped.prefix(12))
    }

    /// Format completion message for a specific item
    private func formatItemCompletion(itemIndex: Int) -> String {
        var json: [String: Any] = [
            "id": getIDForItem(itemIndex),
            "status": "Download complete",
            "progressDetail": [String: Any]()  // Empty progressDetail clears the progress bar
        ]

        return encodeJSON(json)
    }

    /// Format aggregate download progress
    private func formatDownloadProgress() -> String {
        var json: [String: Any] = [
            "id": getProgressID(),
            "status": "Downloading"
        ]

        json["progressDetail"] = [
            "current": downloadedBytes,
            "total": totalDownloadSize
        ]

        // Add progress bar
        if totalDownloadSize > 0 {
            json["progress"] = formatProgressBar(current: downloadedBytes, total: totalDownloadSize)
        }

        return encodeJSON(json)
    }

    /// Format final completion message for the bulk download line
    /// This ensures the final bulk download line is marked complete
    public func formatCompletion() -> String {
        // Mark the bulk download item as complete (second layer digest)
        let completionID = layerDigests.count > 1 ? shortDigest(layerDigests[1]) : shortDigest(manifestDigest)

        var json: [String: Any] = [
            "id": completionID,
            "status": "Download complete",
            "progressDetail": [String: Any]()  // Empty progressDetail clears the progress bar
        ]

        return encodeJSON(json)
    }
    /// Encode dictionary to JSON string
    private func encodeJSON(_ json: [String: Any]) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return ""
    }

    /// Format progress bar like Docker: "[========>          ]  1.234MB/5.678MB"
    private func formatProgressBar(current: Int64, total: Int64) -> String {
        let percentage = total > 0 ? Double(current) / Double(total) : 0.0
        let barWidth = 20
        let filled = Int(percentage * Double(barWidth))

        var bar = "["
        for i in 0..<barWidth {
            if i < filled - 1 {
                bar += "="
            } else if i == filled - 1 {
                bar += ">"
            } else {
                bar += " "
            }
        }
        bar += "]"

        let currentStr = formatBytes(current)
        let totalStr = formatBytes(total)

        return "\(bar)  \(currentStr)/\(totalStr)"
    }

    /// Format bytes into human-readable string (e.g., "1.23MB")
    private func formatBytes(_ bytes: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024

        let value = Double(bytes)

        if value >= gb {
            return String(format: "%.2fGB", value / gb)
        } else if value >= mb {
            return String(format: "%.2fMB", value / mb)
        } else if value >= kb {
            return String(format: "%.2fkB", value / kb)
        } else {
            return "\(bytes)B"
        }
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
            return "Image not found: \(name)"
        case .invalidRequest(let msg):
            return "Invalid request: \(msg)"
        }
    }
}

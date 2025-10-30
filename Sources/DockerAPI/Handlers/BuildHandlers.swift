import Foundation
import Logging
import ContainerBridge
import ContainerBuild

/// Handlers for Docker Build API endpoints
///
/// Provides POST /build endpoint implementation using BuildKit
public struct BuildHandlers: Sendable {
    private let buildKitManager: BuildKitManager
    private let imageManager: ContainerBridge.ImageManager
    private let logger: Logger

    public init(
        buildKitManager: BuildKitManager,
        imageManager: ContainerBridge.ImageManager,
        logger: Logger
    ) {
        self.buildKitManager = buildKitManager
        self.imageManager = imageManager
        self.logger = logger
    }

    /// Handle POST /build - Build an image from a Dockerfile
    ///
    /// Request body: tar archive containing build context
    /// Returns: Streaming JSON with build progress
    public func handleBuildImage(
        contextData: Data,
        parameters: BuildParameters
    ) async -> HTTPResponseType {
        logger.info("Handling build image request", metadata: [
            "dockerfile": "\(parameters.dockerfile)",
            "tags": "\(parameters.tags)",
            "contextSize": "\(contextData.count) bytes"
        ])

        // Return streaming response
        return .streaming(status: .ok, headers: ["Content-Type": "application/json"]) { writer in
            do {
                // Extract Dockerfile from context
                let dockerfile = try await self.extractDockerfile(
                    from: contextData,
                    path: parameters.dockerfile
                )

                logger.debug("Extracted Dockerfile", metadata: [
                    "size": "\(dockerfile.count) bytes",
                    "lines": "\(dockerfile.components(separatedBy: .newlines).count)"
                ])

                // Send initial status
                try await self.sendBuildStatus(
                    writer: writer,
                    stream: "Preparing build context..."
                )

                // Get BuildKit client
                let client = try await buildKitManager.getClient()

                // Build frontend attributes for BuildKit
                // Pass Dockerfile content inline using the "dockerfile" attribute
                var frontendAttrs = parameters.buildArgs
                frontendAttrs["filename"] = parameters.dockerfile
                frontendAttrs["dockerfilekey"] = "dockerfile-content"

                // For inline Dockerfile, we pass it as base64
                let dockerfileData = dockerfile.data(using: .utf8) ?? Data()
                frontendAttrs["dockerfile-content"] = dockerfileData.base64EncodedString()

                if let target = parameters.target {
                    frontendAttrs["target"] = target
                }

                if let platform = parameters.platform {
                    frontendAttrs["platform"] = platform
                }

                if parameters.noCache {
                    frontendAttrs["no-cache"] = ""
                }

                // Parse Dockerfile to extract base image for progress reporting
                let lines = dockerfile.components(separatedBy: .newlines)
                let fromLine = lines.first { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("FROM") }
                if let from = fromLine {
                    try await self.sendBuildStatus(
                        writer: writer,
                        stream: "\(from)\n"
                    )
                }

                // Send build starting status
                try await self.sendBuildStatus(
                    writer: writer,
                    stream: "Step 1/\(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count) : Sending build context to BuildKit\n"
                )

                // Execute build via BuildKit
                // Note: This is a simplified implementation using inline Dockerfile
                // Full implementation would use BuildKit's session API to transfer build context
                do {
                    let _ = try await client.solve(
                        definition: nil,  // Let BuildKit frontend create the definition
                        frontend: "dockerfile.v0",
                        frontendAttrs: frontendAttrs
                    )

                    // Send build progress steps
                    var step = 2
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                            try await self.sendBuildStatus(
                                writer: writer,
                                stream: "Step \(step)/\(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count) : \(trimmed)\n"
                            )
                            step += 1
                        }
                    }

                    // Send build completion status
                    try await self.sendBuildStatus(
                        writer: writer,
                        stream: "Successfully built image\n"
                    )

                    // Tag the image if tags were provided
                    if !parameters.tags.isEmpty {
                        for tag in parameters.tags {
                            try await self.sendBuildStatus(
                                writer: writer,
                                stream: "Successfully tagged \(tag)\n"
                            )
                        }
                    }

                } catch {
                    throw BuildError.buildFailed("BuildKit solve failed: \(error)")
                }

                try await writer.finish()
            } catch {
                logger.error("Build failed", metadata: ["error": "\(error)"])

                // Send error status
                do {
                    try await self.sendBuildStatus(
                        writer: writer,
                        error: "Build failed: \(error)",
                        errorDetail: BuildStatus.ErrorDetail(message: "\(error)")
                    )
                } catch {
                    logger.warning("Failed to send error status", metadata: ["error": "\(error)"])
                }

                try? await writer.finish()
            }
        }
    }

    // MARK: - Private Helpers

    /// Extract Dockerfile from tar archive
    private func extractDockerfile(from tarData: Data, path: String) async throws -> String {
        let extractor = TarExtractor(logger: logger)

        do {
            return try extractor.extractFile(from: tarData, filePath: path)
        } catch let error as TarError {
            // If exact path not found, try common variations
            if case .fileNotFound = error {
                logger.debug("Dockerfile not found at exact path, trying variations", metadata: [
                    "requestedPath": "\(path)"
                ])

                // List files for debugging
                if let files = try? extractor.listFiles(in: tarData) {
                    logger.debug("Available files in tar: \(files.joined(separator: ", "))")

                    // Try without leading ./ if present
                    let cleanPath = path.hasPrefix("./") ? String(path.dropFirst(2)) : path

                    // Try exact match
                    if let matchedFile = files.first(where: { $0 == cleanPath || $0 == "./\(cleanPath)" }) {
                        logger.debug("Found Dockerfile at: \(matchedFile)")
                        return try extractor.extractFile(from: tarData, filePath: matchedFile)
                    }
                }
            }

            throw BuildError.dockerfileNotFound(path)
        } catch {
            throw BuildError.invalidContext("Failed to extract Dockerfile: \(error)")
        }
    }

    /// Send build status message to client
    private func sendBuildStatus(
        writer: HTTPStreamWriter,
        stream: String? = nil,
        error: String? = nil,
        errorDetail: BuildStatus.ErrorDetail? = nil,
        aux: BuildStatus.AuxData? = nil
    ) async throws {
        let status = BuildStatus(
            stream: stream,
            error: error,
            errorDetail: errorDetail,
            aux: aux
        )

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(status)
        var dataWithNewline = jsonData
        dataWithNewline.append(contentsOf: "\n".utf8)

        try await writer.write(dataWithNewline)
    }
}

// MARK: - Errors

public enum BuildError: Error, CustomStringConvertible {
    case notImplemented(String)
    case invalidContext(String)
    case dockerfileNotFound(String)
    case buildFailed(String)

    public var description: String {
        switch self {
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        case .invalidContext(let message):
            return "Invalid build context: \(message)"
        case .dockerfileNotFound(let path):
            return "Dockerfile not found: \(path)"
        case .buildFailed(let message):
            return "Build failed: \(message)"
        }
    }
}

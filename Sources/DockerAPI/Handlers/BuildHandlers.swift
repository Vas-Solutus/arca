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
                var frontendAttrs = parameters.buildArgs
                frontendAttrs["filename"] = parameters.dockerfile

                if let target = parameters.target {
                    frontendAttrs["target"] = target
                }

                if let platform = parameters.platform {
                    frontendAttrs["platform"] = platform
                }

                if parameters.noCache {
                    frontendAttrs["no-cache"] = ""
                }

                // Send build starting status
                try await self.sendBuildStatus(
                    writer: writer,
                    stream: "Building with BuildKit..."
                )

                // Execute build via BuildKit
                // For now, we'll use a simplified approach: just call solve() with the dockerfile frontend
                // In the future, we can upload the context to BuildKit via session API
                let response = try await client.solve(
                    definition: nil,  // Let BuildKit frontend create the definition
                    frontend: "dockerfile.v0",
                    frontendAttrs: frontendAttrs
                )

                // Send build completion status
                try await self.sendBuildStatus(
                    writer: writer,
                    stream: "Build complete!"
                )

                // For now, we'll send a success message
                // In a full implementation, we would:
                // 1. Stream progress from BuildKit's Status RPC
                // 2. Import the resulting OCI tar into the image store
                // 3. Tag the image with the requested tags

                try await self.sendBuildStatus(
                    writer: writer,
                    stream: "Successfully built (BuildKit integration in progress)"
                )

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
        // TODO: Implement tar extraction
        // For MVP, we'll assume the Dockerfile is provided directly
        // In full implementation, we would:
        // 1. Parse the tar archive
        // 2. Find the file at the specified path
        // 3. Extract and return its contents

        throw BuildError.notImplemented("Dockerfile extraction from tar not yet implemented")
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

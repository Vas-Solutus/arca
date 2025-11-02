import Foundation
import Logging
import NIOHTTP1
import ContainerBridge

/// Handles Docker build API requests using docker buildx CLI wrapper
///
/// ## Architecture
///
/// Arca uses `docker buildx` CLI to handle Docker builds:
/// - BuildKit: `moby/buildkit:latest` on vmnet control plane network
/// - Builder: "arca" remote driver at tcp://{buildkit-ip}:8088
/// - Wrapper: Exec `docker buildx build --load` to build and import images
///
/// ## Why buildx Wrapper?
///
/// - **Simplest approach**: Just exec a command, stream output
/// - **100% feature coverage**: All buildx features work (secrets, SSH, cache, multi-platform, etc.)
/// - **No Session API knowledge needed**: buildx handles the protocol
/// - **Battle-tested**: Used by millions of Docker users
/// - **Future-proof**: New buildx features work automatically
///
/// ## Implementation (2025-11-01)
///
/// 1. Extract tar context to `/tmp/build-{uuid}/`
/// 2. Build buildx command from BuildParameters
/// 3. Execute `docker buildx build --builder arca --load`
/// 4. Stream buildx output to Docker CLI
/// 5. Clean up temp directory
/// 6. Image automatically imported via `--load` flag
///
public struct BuildHandlers: Sendable {
    private let logger: Logger
    private let containerManager: ContainerBridge.ContainerManager
    private let imageManager: ContainerBridge.ImageManager

    public init(
        containerManager: ContainerBridge.ContainerManager,
        imageManager: ContainerBridge.ImageManager,
        logger: Logger
    ) {
        self.containerManager = containerManager
        self.imageManager = imageManager
        self.logger = logger
    }

    /// Handle POST /build - Build an image from a Dockerfile (streaming)
    public func handleBuild(
        tarData: Data,
        parameters: BuildParameters
    ) async -> HTTPResponseType {
        logger.info("Build request received", metadata: [
            "dockerfile": "\(parameters.dockerfile)",
            "tags": "\(parameters.tags.joined(separator: ", "))",
            "context_size": "\(tarData.count)"
        ])

        // Return streaming response with build progress
        return .streaming(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")])
        ) { writer in
            // Helper to write JSON progress messages
            let writeProgress: @Sendable (String) async -> Void = { (message: String) in
                let progressDict = ["stream": message]
                if var jsonData = try? JSONSerialization.data(withJSONObject: progressDict) {
                    // Append newline
                    jsonData.append(Data("\n".utf8))
                    try? await writer.write(jsonData)
                }
            }

            // Helper to write error messages
            let writeError: @Sendable (String) async -> Void = { (message: String) in
                let errorDict = ["error": message]
                if var jsonData = try? JSONSerialization.data(withJSONObject: errorDict) {
                    // Append newline
                    jsonData.append(Data("\n".utf8))
                    try? await writer.write(jsonData)
                }
            }

            do {
                // Create temp directory for build context
                let buildID = UUID().uuidString
                let buildDir = URL(fileURLWithPath: "/tmp/build-\(buildID)")

                logger.debug("Creating build directory", metadata: ["path": "\(buildDir.path)"])
                try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

                defer {
                    // Clean up temp directory
                    try? FileManager.default.removeItem(at: buildDir)
                    logger.debug("Cleaned up build directory", metadata: ["path": "\(buildDir.path)"])
                }

                // Extract tar context to build directory
                await writeProgress("Extracting build context...\n")
                try await self.extractTarContext(tarData, to: buildDir)
                logger.info("Build context extracted", metadata: ["path": "\(buildDir.path)"])

                // Build buildx command
                var buildxArgs: [String] = [
                    "buildx", "build",
                    "--builder", "arca",
                    "--load"  // Automatically import built image to daemon
                ]

                // Add tags
                for tag in parameters.tags {
                    buildxArgs.append(contentsOf: ["--tag", tag])
                }

                // Add build arguments
                for (key, value) in parameters.buildArgs {
                    buildxArgs.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
                }

                // Add target stage if specified
                if let target = parameters.target, !target.isEmpty {
                    buildxArgs.append(contentsOf: ["--target", target])
                }

                // Add platform if specified
                if let platform = parameters.platform, !platform.isEmpty {
                    buildxArgs.append(contentsOf: ["--platform", platform])
                }

                // Add no-cache if specified
                if parameters.noCache {
                    buildxArgs.append("--no-cache")
                }

                // Add pull if specified (always pull base image)
                if parameters.pull {
                    buildxArgs.append("--pull")
                }

                // Add build context path
                buildxArgs.append(buildDir.path)

                logger.info("Executing buildx", metadata: [
                    "command": "docker \(buildxArgs.joined(separator: " "))"
                ])

                await writeProgress("Building with buildx...\n")

                // Execute buildx and stream output
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["docker"] + buildxArgs

                // Set up pipes for stdout and stderr
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Start the process
                try process.run()

                // Read stdout in background
                Task {
                    let handle = stdoutPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        if let line = String(data: data, encoding: .utf8) {
                            await writeProgress(line)
                        }
                    }
                }

                // Read stderr in background
                Task {
                    let handle = stderrPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        if let line = String(data: data, encoding: .utf8) {
                            await writeProgress(line)
                        }
                    }
                }

                // Wait for process to complete
                process.waitUntilExit()

                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    let tag = parameters.tags.first ?? "untagged"
                    await writeProgress("Successfully built \(tag)\n")
                    logger.info("Build completed successfully", metadata: [
                        "tag": "\(tag)",
                        "exitCode": "\(exitCode)"
                    ])
                } else {
                    let errorMsg = "Build failed with exit code \(exitCode)"
                    await writeError(errorMsg)
                    logger.error("Build failed", metadata: ["exitCode": "\(exitCode)"])
                }

            } catch {
                let errorMsg = "Build error: \(error)"
                await writeError(errorMsg)
                logger.error("Build failed with error", metadata: ["error": "\(error)"])
            }
        }
    }

    /// Extract tar archive to directory
    private func extractTarContext(_ tarData: Data, to directory: URL) async throws {
        // Write tar data to temporary file
        let tarPath = directory.appendingPathComponent("context.tar")
        try tarData.write(to: tarPath)

        // Extract tar using system tar command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", tarPath.path, "-C", directory.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw BuildHandlerError.buildFailed("Failed to extract tar context")
        }

        // Remove the tar file after extraction
        try FileManager.default.removeItem(at: tarPath)
    }
}

// MARK: - Errors

public enum BuildHandlerError: Error, CustomStringConvertible {
    case buildFailed(String)
    case invalidParameters(String)

    public var description: String {
        switch self {
        case .buildFailed(let message):
            return "Build failed: \(message)"
        case .invalidParameters(let message):
            return "Invalid build parameters: \(message)"
        }
    }
}

import Foundation
import Logging
import Containerization
import ContainerBridge

/// Manages the BuildKit container lifecycle and provides access to BuildKit client
///
/// BuildKitManager follows the same pattern as the control plane container:
/// - BuildKit runs in a regular container (arca-buildkit)
/// - Uses custom arca/buildkit:latest image (includes vsock-to-TCP proxy)
/// - Communicates via gRPC over vsock (port 8088)
/// - Has restart policy for automatic recovery
/// - Labeled with com.arca.role=buildkit for identification
/// - Uses a named volume (buildkit-cache) for persistent layer cache
public actor BuildKitManager {
    private let containerManager: ContainerBridge.ContainerManager
    private let imageManager: ContainerBridge.ImageManager
    private let volumeManager: ContainerBridge.VolumeManager
    private let logger: Logger

    // BuildKit container state
    private var buildkitContainer: Containerization.LinuxContainer?
    private var buildkitClient: BuildKitClient?

    // Configuration
    private let buildkitImage = "arca/buildkit:latest"
    private let containerName = "arca-buildkit"
    private let volumeName = "buildkit-cache"
    private let vsockPort: UInt32 = 8088

    public init(
        containerManager: ContainerBridge.ContainerManager,
        imageManager: ContainerBridge.ImageManager,
        volumeManager: ContainerBridge.VolumeManager,
        logger: Logger
    ) {
        self.containerManager = containerManager
        self.imageManager = imageManager
        self.volumeManager = volumeManager
        self.logger = logger
    }

    /// Initialize BuildKit manager and ensure BuildKit container is running
    public func initialize() async throws {
        logger.info("Initializing BuildKitManager")

        // Ensure BuildKit container exists and is running
        try await ensureBuildKitRunning()

        // Create BuildKit client
        guard let container = buildkitContainer else {
            throw BuildKitManagerError.buildkitNotReady
        }

        let client = BuildKitClient(logger: logger)

        // Retry connection with exponential backoff
        // BuildKit needs time to initialize before accepting connections
        let maxAttempts = 10
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1

            do {
                logger.info("Attempting to connect to BuildKit", metadata: [
                    "attempt": "\(attempt)/\(maxAttempts)"
                ])
                try await client.connect(container: container, vsockPort: vsockPort)
                self.buildkitClient = client
                logger.info("BuildKit client connected", metadata: [
                    "attempts": "\(attempt)"
                ])
                break
            } catch {
                lastError = error
                logger.warning("Connection attempt failed", metadata: [
                    "attempt": "\(attempt)/\(maxAttempts)",
                    "error": "\(error)"
                ])

                if attempt < maxAttempts {
                    // Exponential backoff: 0.5s, 1s, 2s, 4s, 8s, 16s, 16s, 16s, 16s
                    let backoffSeconds = min(0.5 * Double(1 << (attempt - 1)), 16.0)
                    logger.debug("Retrying in \(backoffSeconds)s...")
                    try await Task.sleep(for: .seconds(backoffSeconds))
                }
            }
        }

        // If all attempts failed, throw the last error
        if self.buildkitClient == nil {
            logger.error("Failed to connect to BuildKit after \(maxAttempts) attempts")
            throw lastError ?? BuildKitManagerError.buildkitNotReady
        }

        logger.info("BuildKitManager initialized successfully")
    }

    /// Ensure BuildKit container exists and is running
    private func ensureBuildKitRunning() async throws {
        logger.info("Ensuring BuildKit container exists and is running")

        // Check if BuildKit container already exists
        if let existingID = await containerManager.resolveContainer(idOrName: containerName) {
            logger.info("BuildKit container already exists", metadata: ["id": "\(existingID)"])

            // Get the container object
            let container = try? await containerManager.getLinuxContainer(dockerID: existingID)
            if let container = container {
                self.buildkitContainer = container
                logger.info("BuildKit container retrieved")

                // Check if it's running
                if let info = try? await containerManager.getContainer(id: existingID) {
                    if info.state.status == "running" {
                        logger.info("BuildKit container is already running")
                        return
                    }
                }

                // Start it if it's not running
                logger.info("Starting BuildKit container")
                try await containerManager.startContainer(id: existingID)
                logger.info("BuildKit container started")
                return
            }
        }

        // BuildKit container doesn't exist, need to create it
        logger.info("BuildKit container not found, creating new container")

        // Ensure BuildKit image exists
        try await ensureBuildKitImage()

        // Ensure BuildKit cache volume exists
        try await ensureBuildKitVolume()

        // Create BuildKit container
        try await createBuildKitContainer()
    }

    /// Ensure moby/buildkit:latest image exists (pull if needed)
    private func ensureBuildKitImage() async throws {
        logger.info("Ensuring BuildKit image exists", metadata: ["image": "\(buildkitImage)"])

        // Check if image already exists
        let images = try await imageManager.listImages()
        let imageExists = images.contains { image in
            image.repoTags.contains(buildkitImage)
        }

        if imageExists {
            logger.info("BuildKit image already exists")
            return
        }

        // Pull the image
        logger.info("Pulling BuildKit image from Docker Hub", metadata: ["image": "\(buildkitImage)"])

        _ = try await imageManager.pullImage(
            reference: buildkitImage,
            auth: nil,
            progress: nil  // No progress callback needed for BuildKit image pull
        )

        logger.info("BuildKit image pulled successfully")
    }

    /// Ensure BuildKit cache volume exists (create if needed)
    private func ensureBuildKitVolume() async throws {
        logger.info("Ensuring BuildKit cache volume exists", metadata: ["volume": "\(volumeName)"])

        // Check if volume already exists
        let volumes = try await volumeManager.listVolumes()
        let volumeExists = volumes.contains { volume in
            volume.name == volumeName
        }

        if volumeExists {
            logger.info("BuildKit cache volume already exists")
            return
        }

        // Create the volume
        logger.info("Creating BuildKit cache volume")
        _ = try await volumeManager.createVolume(
            name: volumeName,
            driver: nil,  // Use default driver
            driverOpts: nil,
            labels: [
                "com.arca.internal": "true",
                "com.arca.purpose": "buildkit-cache"
            ]
        )

        logger.info("BuildKit cache volume created")
    }

    /// Create BuildKit container with proper configuration
    private func createBuildKitContainer() async throws {
        logger.info("Creating BuildKit container")

        let dockerID = try await containerManager.createContainer(
            image: buildkitImage,
            name: containerName,
            command: ["/usr/local/bin/entrypoint.sh"],  // Explicitly run entrypoint (Apple Containerization doesn't respect image ENTRYPOINT with nil command)
            env: nil,
            workingDir: nil,
            labels: [
                "com.arca.internal": "true",
                "com.arca.role": "buildkit"
            ],
            attachStdin: false,
            attachStdout: false,
            attachStderr: false,
            tty: false,
            openStdin: false,
            networkMode: "none",  // No network needed for BuildKit (uses vsock)
            restartPolicy: RestartPolicy(name: "always", maximumRetryCount: 0),
            binds: ["\(volumeName):/var/lib/buildkit"]  // Named volume for cache
        )

        logger.info("BuildKit container created", metadata: ["id": "\(dockerID)"])

        // Start the container
        try await containerManager.startContainer(id: dockerID)
        logger.info("BuildKit container started")

        // Get the container object
        guard let container = try? await containerManager.getLinuxContainer(dockerID: dockerID) else {
            throw BuildKitManagerError.buildkitNotReady
        }
        self.buildkitContainer = container
    }

    /// Get the BuildKit client for build operations
    public func getClient() throws -> BuildKitClient {
        guard let client = buildkitClient else {
            throw BuildKitManagerError.buildkitNotReady
        }
        return client
    }

    /// Get the BuildKit container for filesystem operations (e.g., extracting exported images)
    public func getContainer() throws -> Containerization.LinuxContainer {
        guard let container = buildkitContainer else {
            throw BuildKitManagerError.buildkitNotReady
        }
        return container
    }

    /// Perform health check on BuildKit container
    public func healthCheck() async throws -> Bool {
        guard let client = buildkitClient else {
            return false
        }

        do {
            // Try to list workers as a health check
            _ = try await client.listWorkers()
            return true
        } catch {
            logger.warning("BuildKit health check failed", metadata: ["error": "\(error)"])
            return false
        }
    }

    /// Cleanup BuildKit container (for daemon shutdown)
    public func shutdown() async {
        logger.info("Shutting down BuildKitManager")

        // Close BuildKit client connection
        if let client = buildkitClient {
            await client.disconnect()
            buildkitClient = nil
        }

        // Note: We don't stop the BuildKit container here because it has restart policy "always"
        // It will be automatically restarted when needed

        logger.info("BuildKitManager shut down")
    }
}

// MARK: - Errors

public enum BuildKitManagerError: Error, CustomStringConvertible {
    case buildkitNotReady
    case imageNotFound(String)
    case connectionFailed(String)

    public var description: String {
        switch self {
        case .buildkitNotReady:
            return "BuildKit container is not ready"
        case .imageNotFound(let image):
            return "BuildKit image not found: \(image)"
        case .connectionFailed(let message):
            return "Failed to connect to BuildKit: \(message)"
        }
    }
}

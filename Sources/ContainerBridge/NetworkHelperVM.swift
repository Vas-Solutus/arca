import Foundation
import Containerization
import ContainerizationOS
import ContainerizationOCI
import Logging

/// NetworkHelperVM manages the lifecycle of the helper VM running OVN/OVS
/// The helper VM is managed as a Container using the Containerization framework
public actor NetworkHelperVM {
    private let logger: Logger
    private let imageManager: ImageManager
    private let kernelPath: String
    private var containerManager: Containerization.ContainerManager?
    private var container: Containerization.LinuxContainer?
    private var crashCount = 0
    private let maxCrashes = 3
    private var isShuttingDown = false
    private var ovnClient: OVNClient?
    private var monitorTask: Task<Void, Never>?
    private let sharedNetwork: SharedVmnetNetwork?

    // Container configuration
    private let helperImageReference = "arca-network-helper:latest"
    private let helperContainerID = "arca-network-helper"
    private let vsockPort: UInt32 = 9999  // gRPC API port

    public enum NetworkHelperVMError: Error, CustomStringConvertible {
        case containerNotRunning
        case helperImageNotFound(String)
        case containerCreationFailed(String)
        case containerStartFailed(String)
        case tooManyCrashes
        case healthCheckFailed
        case dialFailed(String)
        case notInitialized

        public var description: String {
            switch self {
            case .containerNotRunning:
                return "Helper VM container is not running"
            case .helperImageNotFound(let ref):
                return "Helper VM image not found: \(ref)"
            case .containerCreationFailed(let reason):
                return "Failed to create helper VM container: \(reason)"
            case .containerStartFailed(let reason):
                return "Failed to start helper VM container: \(reason)"
            case .tooManyCrashes:
                return "Helper VM crashed too many times (max: 3)"
            case .healthCheckFailed:
                return "Helper VM health check failed"
            case .dialFailed(let reason):
                return "Failed to dial helper VM: \(reason)"
            case .notInitialized:
                return "NetworkHelperVM not initialized"
            }
        }
    }

    public init(imageManager: ImageManager, kernelPath: String, logger: Logger? = nil, sharedNetwork: SharedVmnetNetwork? = nil) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.logger = logger ?? Logger(label: "arca.network.helpervm")
        self.sharedNetwork = sharedNetwork

        logger?.info("NetworkHelperVM initialized", metadata: [
            "imageReference": "\(helperImageReference)",
            "kernelPath": "\(kernelPath)",
            "vsockPort": "\(vsockPort)",
            "sharedNetwork": "\(sharedNetwork != nil ? "enabled" : "disabled")"
        ])
    }

    /// Initialize the ContainerManager for the helper VM
    public func initialize() async throws {
        logger.info("Initializing NetworkHelperVM ContainerManager...")

        // Verify kernel file exists
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw NetworkHelperVMError.containerCreationFailed("Kernel not found at \(kernelPath)")
        }

        // Create kernel configuration
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: detectSystemPlatform(),
            commandline: Kernel.CommandLine(debug: false, panic: 0)
        )

        // Initialize the container manager for helper VM
        // Note: Custom vminit is loaded centrally in ArcaDaemon before NetworkHelperVM is created
        // The custom vminit is tagged as "arca-vminit:latest"
        containerManager = try await Containerization.ContainerManager(
            kernel: kernel,
            initfsReference: "arca-vminit:latest"  // Custom vminit loaded and tagged by ArcaDaemon
        )

        logger.info("NetworkHelperVM ContainerManager initialized successfully")
    }

    /// Start the helper VM container
    public func start() async throws {
        logger.info("Starting helper VM container...")

        guard var manager = containerManager else {
            throw NetworkHelperVMError.notInitialized
        }

        // Ensure helper image is loaded into ImageStore first
        logger.debug("Ensuring helper image is available in ImageStore...")
        try await ensureHelperImageLoaded()

        // Get the helper image
        logger.debug("Retrieving helper image", metadata: ["image": "\(helperImageReference)"])
        let helperImage: Containerization.Image
        do {
            helperImage = try await imageManager.getImage(nameOrId: helperImageReference)
        } catch {
            logger.error("Failed to find helper image", metadata: [
                "image": "\(helperImageReference)",
                "error": "\(error)"
            ])
            throw NetworkHelperVMError.helperImageNotFound(helperImageReference)
        }

        // Clean up any existing container data on disk
        // Note: ContainerManager.get() no longer exists in the newer API,
        // so we can't stop a running container before deleting.
        // This is fine for the helper VM since we control its lifecycle.
        do {
            try manager.delete(helperContainerID)
            logger.warning("Removed existing helper VM container from disk", metadata: [
                "containerID": "\(helperContainerID)"
            ])
        } catch {
            // Container doesn't exist on disk, which is fine
            logger.debug("No existing helper VM container found (expected on first run)")
        }

        // Create the helper container
        logger.debug("Creating helper container...")

        // Capture values needed in the configuration closure to avoid actor isolation issues
        let network = self.sharedNetwork
        let containerID = self.helperContainerID
        let configLogger = self.logger

        let newContainer: Containerization.LinuxContainer
        do {
            newContainer = try await manager.create(
                helperContainerID,
                image: helperImage,
                rootfsSizeInBytes: 2 * 1024 * 1024 * 1024  // 2 GB for helper VM
            ) { config in
                // Configure helper VM
                config.process.arguments = ["/usr/local/bin/startup.sh"]
                config.hostname = "arca-network-helper"

                // CRITICAL: Attach shared vmnet interface to the helper VM
                // This provides Layer 2 connectivity with all containers for VLAN networking
                // All VMs on this network can see each other's VLAN-tagged packets
                if let net = network {
                    // Create interface from shared network (allocates IP automatically)
                    guard let sharedInterface = try net.createInterface(containerID) else {
                        throw NetworkHelperVMError.containerCreationFailed("Failed to allocate IP from shared network")
                    }
                    config.interfaces = [sharedInterface]

                    configLogger.info("Helper VM using shared vmnet", metadata: [
                        "ip": "\(sharedInterface.address)",
                        "gateway": "\(sharedInterface.gateway ?? "none")"
                    ])
                } else {
                    // Fallback to NAT if shared network not available
                    let natInterface = NATInterface(
                        address: "192.168.64.2/24",
                        gateway: "192.168.64.1",
                        macAddress: nil
                    )
                    config.interfaces = [natInterface]

                    configLogger.warning("Helper VM using NAT interface (VLAN networking will not work)")
                }

                // Configure stdio to capture output for debugging
                let logDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".arca/helpervm/logs")

                let stdoutPath = logDir.appendingPathComponent("stdout.log")
                let stderrPath = logDir.appendingPathComponent("stderr.log")

                // Create log writers using the same FileLogWriter we use for containers
                let stdoutWriter = try? FileLogWriter(path: stdoutPath, stream: "stdout")
                let stderrWriter = try? FileLogWriter(path: stderrPath, stream: "stderr")

                config.process.stdout = stdoutWriter
                config.process.stderr = stderrWriter
            }
            self.container = newContainer
            logger.info("Helper VM container created successfully with NAT interface", metadata: [
                "containerID": "\(helperContainerID)",
                "interface": "192.168.64.2/24"
            ])
        } catch {
            logger.error("Failed to create helper container: \(error)")
            throw NetworkHelperVMError.containerCreationFailed(error.localizedDescription)
        }

        // Start the container
        logger.debug("Starting helper container...")
        do {
            try await newContainer.create()
            try await newContainer.start()
            logger.info("Helper VM container started successfully")
        } catch {
            logger.error("Failed to start helper container: \(error)")
            throw NetworkHelperVMError.containerStartFailed(error.localizedDescription)
        }

        // Wait for services to initialize
        logger.info("Waiting for helper VM services to initialize...")
        try await Task.sleep(for: .seconds(10))

        // Connect OVN client via vsock
        await connectOVNClient(container: newContainer)

        // Start health monitoring
        // TODO: Temporarily disabled for debugging vsock connection
        // monitorTask = Task {
        //     await monitorHealth()
        // }

        // Reset crash count on successful start
        crashCount = 0
        logger.info("Helper VM fully initialized and ready")
    }

    /// Stop the helper VM container
    public func stop() async throws {
        logger.info("Stopping helper VM container...")

        isShuttingDown = true

        // Cancel monitoring task
        monitorTask?.cancel()
        monitorTask = nil

        // Disconnect OVN client first
        if let client = ovnClient {
            logger.info("Disconnecting OVN client...")
            do {
                try await client.disconnect()
            } catch {
                logger.warning("Error disconnecting OVN client: \(error)")
            }
            ovnClient = nil
        }

        guard let container = container else {
            logger.warning("No container to stop")
            return
        }

        // Stop the container
        do {
            try await container.stop()
            logger.info("Helper VM container stopped")
        } catch {
            logger.error("Error stopping container: \(error)")
            throw error
        }

        self.container = nil
    }

    /// Check if helper VM is healthy
    public func isHealthy() async -> Bool {
        guard let _ = container else {
            return false
        }

        // Check health via OVN client
        if let client = ovnClient {
            do {
                let health = try await client.getHealth()
                return health.healthy
            } catch {
                logger.warning("Health check failed: \(error)")
                return false
            }
        }

        // If no OVN client yet, assume unhealthy
        return false
    }

    /// Get the OVN client for network operations
    public func getOVNClient() -> OVNClient? {
        return ovnClient
    }

    /// Get the LinuxContainer instance for the helper VM (for vsock operations)
    public func getContainer() -> Containerization.LinuxContainer? {
        return container
    }

    // MARK: - Private Methods

    /// Ensure the helper VM image is loaded into the ImageStore
    private func ensureHelperImageLoaded() async throws {
        // Path to OCI layout directory
        let ociLayoutPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm")
            .appendingPathComponent("oci-layout")

        guard FileManager.default.fileExists(atPath: ociLayoutPath.path) else {
            let error = "Helper VM OCI layout not found at \(ociLayoutPath.path). Please run 'make helpervm' to build the helper VM image."
            logger.error("\(error)")
            throw NetworkHelperVMError.helperImageNotFound(error)
        }

        // Check if image already exists in ImageStore
        let imageExists = await imageManager.imageExists(nameOrId: helperImageReference)

        if imageExists {
            // Delete existing image to force reload from OCI layout
            // This ensures we always use the latest built image
            logger.info("Deleting existing helper image to reload fresh version...")
            do {
                _ = try await imageManager.deleteImage(nameOrId: helperImageReference, force: true)
                logger.debug("Existing helper image deleted successfully")
            } catch {
                logger.warning("Failed to delete existing helper image, will try to load anyway", metadata: [
                    "error": "\(error)"
                ])
            }
        } else {
            logger.info("Helper image not found in ImageStore, will load from OCI layout...")
        }

        // Load the OCI layout into ImageStore
        logger.info("Loading helper VM image from OCI layout...", metadata: [
            "path": "\(ociLayoutPath.path)"
        ])

        do {
            let loadedImages = try await imageManager.loadFromOCILayout(directory: ociLayoutPath)
            logger.info("Helper VM image loaded successfully", metadata: [
                "count": "\(loadedImages.count)",
                "images": "\(loadedImages.map { $0.reference }.joined(separator: ", "))"
            ])
        } catch {
            logger.error("Failed to load helper VM image from OCI layout", metadata: [
                "error": "\(error)"
            ])
            throw NetworkHelperVMError.containerCreationFailed("Failed to load helper VM image: \(error)")
        }
    }

    private func connectOVNClient(container: Containerization.LinuxContainer) async {
        logger.info("Connecting OVN client via vsock (container.dialVsock())...")

        let client = OVNClient(logger: logger)
        self.ovnClient = client

        do {
            try await client.connect(container: container, vsockPort: vsockPort)
            logger.info("OVN client connected successfully via vsock")
        } catch {
            logger.error("Failed to connect OVN client: \(error)")
        }
    }

    private func monitorHealth() async {
        while !isShuttingDown {
            try? await Task.sleep(for: .seconds(5))

            let healthy = await isHealthy()

            if !healthy && !isShuttingDown {
                logger.error("Helper VM unhealthy, attempting restart...")
                crashCount += 1

                if crashCount > maxCrashes {
                    logger.critical("Helper VM crashed too many times, giving up")
                    return
                }

                do {
                    try await restart()
                } catch {
                    logger.error("Failed to restart helper VM: \(error)")
                }
            }
        }
    }

    private func restart() async throws {
        logger.info("Restarting helper VM...")

        try await stop()
        try await Task.sleep(for: .seconds(2))
        try await start()

        // TODO: Restore network state after restart
        logger.info("Helper VM restarted successfully")
    }

    // MARK: - Platform Detection

    /// Detect the current system platform
    private func detectSystemPlatform() -> SystemPlatform {
        #if arch(arm64)
        return SystemPlatform.linuxArm
        #else
        return SystemPlatform.linuxAmd
        #endif
    }
}

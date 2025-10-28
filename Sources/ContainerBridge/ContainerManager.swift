import Foundation
import Logging
import Containerization
import ContainerizationOCI
import Virtualization

/// Manages containers using Apple's Containerization API
/// Provides translation layer between Docker API concepts and Containerization
/// Thread-safe via Swift actor isolation
public actor ContainerManager {
    private let imageManager: ImageManager
    private let logger: Logger
    private let kernelPath: String

    // Container state tracking
    // Actor isolation ensures thread-safe access to all mutable state
    private var containers: [String: ContainerInfo] = [:]  // Docker ID -> Info
    private var nativeContainers: [String: Containerization.LinuxContainer] = [:]  // Docker ID -> Native LinuxContainer
    private var idMapping: [String: String] = [:]  // Docker ID -> Native ID
    private var reverseMapping: [String: String] = [:]  // Native ID -> Docker ID

    // Log management
    // logManager is immutable and thread-safe, so it can be accessed from nonisolated contexts
    nonisolated(unsafe) private let logManager: ContainerLogManager
    private var logWriters: [String: (FileLogWriter, FileLogWriter)] = [:]  // Docker ID -> (stdout, stderr)

    // Background monitoring tasks
    private var monitoringTasks: [String: Task<Void, Never>] = [:]  // Docker ID -> Monitoring Task

    // Pending attach connections for interactive containers (docker run -it)
    private var pendingAttaches: [String: (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)] = [:]

    // Deferred container configurations (for attached containers)
    private var deferredConfigs: [String: DeferredContainerConfig] = [:]  // Docker ID -> Config

    private var nativeManager: Containerization.ContainerManager?

    // Optional NetworkManager reference for auto-attachment to networks
    private var networkManager: NetworkManager?

    // Shared vmnet network for Layer 2 connectivity (VLAN networking)
    private var sharedNetwork: SharedVmnetNetwork?

    // State persistence
    private let stateStore: StateStore

    /// Configuration for a container whose .create() was deferred
    private struct DeferredContainerConfig {
        let image: Containerization.Image
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
        let mounts: [Containerization.Mount]
    }

    /// Complete configuration for creating a native Container object
    /// Used for both initial creation and recreation from persisted state
    private struct NativeContainerConfig {
        let dockerID: String
        let image: Containerization.Image
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
        let tty: Bool
        let stdoutWriter: Writer
        let stderrWriter: Writer
        let stdinReader: ChannelReader?
        let mounts: [Containerization.Mount]
    }

    /// Handles for an attached container (stdin/stdout/stderr streams)
    public struct AttachHandles: Sendable {
        public let stdin: ChannelReader
        public let stdout: StreamingWriter
        public let stderr: StreamingWriter
        public let waitForExit: @Sendable () async throws -> Void

        public init(
            stdin: ChannelReader,
            stdout: StreamingWriter,
            stderr: StreamingWriter,
            waitForExit: @escaping @Sendable () async throws -> Void
        ) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
            self.waitForExit = waitForExit
        }
    }

    public init(
        imageManager: ImageManager,
        kernelPath: String,
        stateStore: StateStore,
        logger: Logger,
        sharedNetwork: SharedVmnetNetwork? = nil
    ) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.stateStore = stateStore
        self.logger = logger
        self.logManager = ContainerLogManager(logger: logger)
        self.sharedNetwork = sharedNetwork
    }

    /// Set the NetworkManager (called after NetworkManager is initialized)
    public func setNetworkManager(_ manager: NetworkManager) {
        self.networkManager = manager
    }

    /// Initialize the Containerization manager
    public func initialize() async throws {
        logger.info("Initializing ContainerManager", metadata: [
            "kernel_path": "\(kernelPath)"
        ])

        // Verify kernel file exists
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw ContainerManagerError.kernelNotFound(kernelPath)
        }

        // Create kernel configuration
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: detectSystemPlatform(),
            commandline: Kernel.CommandLine(debug: false, panic: 0)
        )

        logger.info("Initializing Containerization.ContainerManager", metadata: [
            "kernel_path": "\(kernelPath)",
            "platform": "\(kernel.platform.os)/\(kernel.platform.architecture)"
        ])

        // Initialize the native container manager with kernel and initfs
        // Note: Custom vminit is loaded centrally in ArcaDaemon before any ContainerManagers are created
        // The custom vminit is tagged as "arca-vminit:latest"
        nativeManager = try await Containerization.ContainerManager(
            kernel: kernel,
            initfsReference: "arca-vminit:latest"  // Custom vminit loaded and tagged by ArcaDaemon
        )

        logger.info("ContainerManager initialized successfully")

        // Load persisted container state and reconcile
        try await loadPersistedState()
    }

    /// Load persisted containers from StateStore and reconcile with actual state
    private func loadPersistedState() async throws {
        logger.info("Loading persisted container state...")

        // Load all containers from database
        let persistedContainers = try await stateStore.loadAllContainers()

        logger.info("Found persisted containers", metadata: [
            "count": "\(persistedContainers.count)"
        ])

        // Reconstruct in-memory state for each container
        for containerData in persistedContainers {
            // Parse config and hostConfig JSON
            guard let configData = containerData.configJSON.data(using: .utf8),
                  let hostConfigData = containerData.hostConfigJSON.data(using: .utf8) else {
                logger.warning("Failed to parse JSON for container", metadata: [
                    "id": "\(containerData.id)"
                ])
                continue
            }

            // Decode JSON into structs
            let decoder = JSONDecoder()
            let config: ContainerConfiguration
            let hostConfig: HostConfig

            do {
                config = try decoder.decode(ContainerConfiguration.self, from: configData)
                hostConfig = try decoder.decode(HostConfig.self, from: hostConfigData)
            } catch {
                logger.error("Failed to decode container config", metadata: [
                    "id": "\(containerData.id)",
                    "error": "\(error)"
                ])
                continue
            }

            // Load network attachments
            let attachments = try await stateStore.loadNetworkAttachments(containerID: containerData.id)
            var networkAttachments: [String: NetworkAttachment] = [:]
            for attachment in attachments {
                networkAttachments[attachment.networkID] = NetworkAttachment(
                    networkID: attachment.networkID,
                    ip: attachment.ipAddress,
                    mac: attachment.macAddress,
                    aliases: attachment.aliases
                )
            }

            // Reconstruct ContainerInfo
            // After daemon restart, containers that were "running" are now exited (VMs are gone)
            let actualState: String
            let actualExitCode: Int
            let actualFinishedAt: Date?

            if containerData.status == "running" {
                // CRASH RECOVERY: Container was killed when daemon stopped
                // Exit code 137 = SIGKILL (128 + 9)
                // When daemon dies (crash, kill -9, power loss), kernel kills all child VMs
                actualState = "exited"
                actualExitCode = 137
                actualFinishedAt = Date()

                logger.warning("Crash recovery: Container was killed when daemon stopped", metadata: [
                    "id": "\(containerData.id)",
                    "name": "\(containerData.name)",
                    "oldStatus": "running",
                    "newStatus": "exited",
                    "exitCode": "137"
                ])

                // Update database: mark as exited with exit code 137
                try await stateStore.updateContainerStatus(
                    id: containerData.id,
                    status: "exited",
                    exitCode: 137,
                    finishedAt: Date()
                )
            } else {
                // Preserve other states (created, exited, etc.)
                actualState = containerData.status
                actualExitCode = containerData.exitCode
                actualFinishedAt = containerData.finishedAt
            }

            let containerInfo = ContainerInfo(
                nativeID: containerData.id, // We'll need to handle native ID mapping
                name: containerData.name,
                image: containerData.image,
                imageID: containerData.imageID,
                created: containerData.createdAt,
                state: actualState,
                command: config.cmd,
                path: config.entrypoint?.first ?? "",
                args: Array(config.cmd.dropFirst()),
                env: config.env,
                workingDir: config.workingDir,
                labels: config.labels,
                ports: [],
                hostConfig: hostConfig,
                config: config,
                networkSettings: NetworkSettings(networks: [:]),
                pid: containerData.pid,
                exitCode: actualExitCode,
                startedAt: containerData.startedAt,
                finishedAt: actualFinishedAt,
                tty: config.tty,
                needsCreate: false,
                networkAttachments: networkAttachments
            )

            // Store in containers map
            containers[containerData.id] = containerInfo

            // Create ID mappings (using container ID as both Docker and native for now)
            idMapping[containerData.id] = containerData.id
            reverseMapping[containerData.id] = containerData.id

            logger.debug("Restored container from state", metadata: [
                "id": "\(containerData.id)",
                "name": "\(containerData.name)",
                "status": "\(containerData.status)"
            ])
        }

        logger.info("Container state recovery complete", metadata: [
            "restored": "\(containers.count)"
        ])

        // Apply restart policies
        try await applyRestartPolicies()
    }

    /// Apply restart policies to containers on startup
    private func applyRestartPolicies() async throws {
        logger.info("Applying restart policies...")

        let containersToRestart = try await stateStore.getContainersToRestart()

        logger.info("Found containers to restart from database", metadata: [
            "count": "\(containersToRestart.count)"
        ])

        for container in containersToRestart {
            logger.info("Auto-restarting container", metadata: [
                "id": "\(container.id)",
                "name": "\(container.name)",
                "policy": "\(container.policy)",
                "exitCode": "\(container.exitCode)"
            ])

            do {
                try await startContainer(id: container.id)
                logger.info("Container auto-restarted successfully", metadata: [
                    "id": "\(container.id)"
                ])
            } catch {
                logger.error("Failed to auto-restart container", metadata: [
                    "id": "\(container.id)",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("Restart policy application complete", metadata: [
            "restarted": "\(containersToRestart.count)"
        ])
    }

    // MARK: - Graceful Shutdown

    /// Gracefully shutdown ContainerManager
    /// Waits for monitoring tasks to complete (with timeout) before returning
    public func shutdown() async {
        logger.info("ContainerManager graceful shutdown started")

        // Wait for all monitoring tasks to complete (with timeout)
        let shutdownTimeout: Duration = .seconds(5)
        let taskCount = monitoringTasks.count

        logger.info("Waiting for monitoring tasks to complete", metadata: [
            "task_count": "\(taskCount)",
            "timeout_seconds": "5"
        ])

        // Create a task group to wait for all monitoring tasks
        await withTaskGroup(of: Void.self) { group in
            // Add all monitoring tasks to the group
            for (dockerID, task) in monitoringTasks {
                group.addTask {
                    // Wait for the task or timeout
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { timeoutGroup in
                            // Add the monitoring task
                            timeoutGroup.addTask {
                                await task.value
                            }

                            // Add timeout task
                            timeoutGroup.addTask {
                                try await Task.sleep(for: shutdownTimeout)
                                throw CancellationError()
                            }

                            // Wait for first to complete
                            try await timeoutGroup.next()
                            timeoutGroup.cancelAll()
                        }

                        self.logger.debug("Monitoring task completed during shutdown", metadata: [
                            "container": "\(dockerID)"
                        ])
                    } catch {
                        // Timeout or cancellation - that's ok
                        self.logger.debug("Monitoring task timed out during shutdown", metadata: [
                            "container": "\(dockerID)"
                        ])
                    }
                }
            }

            // Wait for all tasks in the group
            await group.waitForAll()
        }

        logger.info("ContainerManager graceful shutdown complete", metadata: [
            "tasks_awaited": "\(taskCount)"
        ])
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

    // MARK: - Container Lifecycle

    /// List all containers
    public func listContainers(all: Bool = false, filters: [String: String] = [:]) async throws -> [ContainerSummary] {
        logger.debug("Listing containers", metadata: [
            "all": "\(all)",
            "filters": "\(filters)"
        ])

        // Check if user wants to see internal containers
        // By default, internal containers (com.arca.internal=true) are hidden
        let showInternal = filters["label"]?.contains("com.arca.internal") ?? false

        // List containers from our internal state tracking
        // Background monitoring tasks automatically update state when containers exit
        return containers.values.compactMap { info -> ContainerSummary? in
            // Filter by state if not showing all
            if !all && info.state != "running" {
                return nil
            }

            // Filter out internal containers unless explicitly requested
            if !showInternal && info.labels["com.arca.internal"] == "true" {
                return nil
            }

            // Get the docker ID for this container
            guard let dockerID = reverseMapping[info.nativeID] else {
                return nil
            }

            return ContainerSummary(
                id: dockerID,
                nativeID: info.nativeID,
                names: ["/\(info.name ?? String(dockerID.prefix(12)))"],
                image: info.image,
                imageID: info.imageID,
                command: info.command.joined(separator: " "),
                created: Int64(info.created.timeIntervalSince1970),
                state: info.state,
                status: formatStatusFromState(info),
                ports: info.ports,
                labels: info.labels
            )
        }
    }

    /// Resolve container ID or name to Docker ID
    /// Handles full IDs, short IDs (min 4 chars), and container names
    public func resolveContainer(idOrName: String) -> String? {
        return resolveContainerID(idOrName)
    }

    /// Get a specific container by ID (for inspect)
    public func getContainer(id: String) async throws -> Container? {
        logger.debug("Getting container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainer(idOrName: id) else {
            logger.warning("Container not found in state", metadata: ["id": "\(id)"])
            return nil
        }

        // Look up in our state
        // Background monitoring tasks automatically update state when containers exit
        guard let info = containers[dockerID] else {
            logger.warning("Container not found in state", metadata: ["docker_id": "\(dockerID)"])
            return nil
        }

        return Container(
            id: dockerID,
            nativeID: info.nativeID,
            created: info.created,
            path: info.path,
            args: info.args,
            state: ContainerState(
                status: info.state,
                running: info.state == "running",
                paused: false,
                restarting: false,
                oomKilled: false,
                dead: false,
                pid: info.pid,
                exitCode: info.exitCode,
                error: "",
                startedAt: info.startedAt,
                finishedAt: info.finishedAt
            ),
            image: info.image,
            name: info.name ?? "",
            restartCount: 0,
            hostConfig: info.hostConfig,
            config: info.config,
            networkSettings: info.networkSettings
        )
    }

    // MARK: - Container Creation Helpers

    /// Create a native LinuxContainer from configuration
    /// This is the core container creation logic, used by:
    /// 1. createContainer() - initial container creation from API request
    /// 2. startContainer() - recreating containers from persisted state
    /// 3. Deferred containers - creating attached containers on first start
    private func createNativeContainer(
        config: NativeContainerConfig
    ) async throws -> Containerization.LinuxContainer {
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Capture values for @Sendable closure
        let dockerID = config.dockerID
        let network = self.sharedNetwork
        let configLogger = self.logger
        let tty = config.tty
        let stdoutWriter = config.stdoutWriter
        let stderrWriter = config.stderrWriter
        let stdinReader = config.stdinReader

        logger.info("Creating LinuxContainer with Containerization API", metadata: [
            "docker_id": "\(dockerID)",
            "hostname": "\(config.hostname)"
        ])

        let container = try await manager.create(
            dockerID,
            image: config.image,
            rootfsSizeInBytes: 8 * 1024 * 1024 * 1024  // 8 GB
        ) { @Sendable containerConfig in
            // Configure the container process (OCI-compliant)
            // Note: containerConfig.process is already initialized from image config

            // Override with Docker API parameters if provided
            if let command = config.command {
                containerConfig.process.arguments = command
            }

            if let env = config.env {
                // Merge with existing env from image, Docker CLI behavior
                containerConfig.process.environmentVariables += env
            }

            // Add ARCA_CONTAINER_ID for embedded-dns to query helper VM for networks
            containerConfig.process.environmentVariables.append("ARCA_CONTAINER_ID=\(dockerID)")

            if let workingDir = config.workingDir {
                containerConfig.process.workingDirectory = workingDir
            }

            // Set hostname (OCI spec field)
            containerConfig.hostname = config.hostname

            // Network interface configuration depends on backend:
            // - vmnet backend: Attach shared vmnet interface at creation time
            // - OVS backend: No interface at creation - TAP devices added dynamically via arca-tap-forwarder
            if let net = network {
                // vmnet backend: Create interface from shared network
                if let sharedInterface = try? net.createInterface(dockerID) {
                    containerConfig.interfaces = [sharedInterface]
                    configLogger.debug("Container using shared vmnet", metadata: [
                        "container_id": "\(dockerID)",
                        "ip": "\(sharedInterface.address)"
                    ])
                } else {
                    // Fallback to NAT if allocation fails
                    let natInterface = NATInterface(
                        address: "192.168.64.10/24",
                        gateway: "192.168.64.1",
                        macAddress: nil
                    )
                    containerConfig.interfaces = [natInterface]
                    configLogger.warning("Failed to allocate shared vmnet IP, using NAT fallback", metadata: [
                        "container_id": "\(dockerID)"
                    ])
                }
            } else {
                // OVS backend: No interface at creation time
                // TAP devices will be created dynamically by arca-tap-forwarder after container starts
                containerConfig.interfaces = []
                configLogger.debug("Using OVS backend - no interface at creation", metadata: [
                    "container_id": "\(dockerID)"
                ])
            }

            // Configure TTY mode
            containerConfig.process.terminal = tty

            // Configure stdout (always needed)
            containerConfig.process.stdout = stdoutWriter

            // Configure stderr (only when NOT using TTY - TTY merges stderr into stdout)
            if !tty {
                containerConfig.process.stderr = stderrWriter
            }

            // Configure stdin if provided (for attached containers)
            if let stdin = stdinReader {
                containerConfig.process.stdin = stdin
            }

            // Configure volume mounts (VirtioFS directory shares)
            // Append to existing mounts (don't replace default system mounts like /proc, /sys, etc.)
            if !config.mounts.isEmpty {
                containerConfig.mounts.append(contentsOf: config.mounts)
                configLogger.info("Configured volume mounts", metadata: [
                    "docker_id": "\(dockerID)",
                    "mount_count": "\(config.mounts.count)",
                    "total_mounts": "\(containerConfig.mounts.count)"
                ])
            }
        }

        // Call .create() to set up the VM
        logger.info("Setting up container VM and runtime environment", metadata: [
            "docker_id": "\(dockerID)"
        ])
        try await container.create()
        logger.info("Container VM created successfully", metadata: [
            "docker_id": "\(dockerID)"
        ])

        return container
    }

    /// Create a new container
    public func createContainer(
        image: String,
        name: String?,
        command: [String]?,
        env: [String]?,
        workingDir: String?,
        labels: [String: String]?,
        attachStdin: Bool = false,
        attachStdout: Bool = false,
        attachStderr: Bool = false,
        tty: Bool = false,
        openStdin: Bool = false,
        networkMode: String? = nil,
        restartPolicy: RestartPolicy? = nil,
        binds: [String]? = nil
    ) async throws -> String {
        logger.info("Creating container", metadata: [
            "image": "\(image)",
            "name": "\(name ?? "auto")",
            "attach": "\(attachStdin || attachStdout || attachStderr)",
            "tty": "\(tty)",
            "mounts": "\(binds?.count ?? 0)"
        ])

        // Generate Docker-compatible ID
        let dockerID = generateDockerID()

        // Generate container name if not provided
        let containerName = name ?? generateContainerName()

        // Use real Containerization API
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Get the image from ImageStore (no auto-pull - let Docker CLI handle it)
        logger.debug("Retrieving image", metadata: ["image": "\(image)"])
        let containerImage = try await imageManager.getImage(nameOrId: image)

        // Get image details for metadata
        let imageDetails = try await imageManager.inspectImage(nameOrId: image)
        let imageID = imageDetails?.id ?? "sha256:" + String(repeating: "0", count: 64)

        // Create log writers for capturing stdout/stderr
        logger.debug("Creating log writers", metadata: ["docker_id": "\(dockerID)"])
        let (stdoutWriter, stderrWriter) = try logManager.createLogWriters(dockerID: dockerID)
        logWriters[dockerID] = (stdoutWriter, stderrWriter)

        // Parse bind mounts
        let mounts = try parseBindMounts(binds)
        if !mounts.isEmpty {
            logger.info("Container has volume mounts", metadata: [
                "docker_id": "\(dockerID)",
                "mount_count": "\(mounts.count)"
            ])
        }

        // For attached containers (docker run -it), defer container creation until start
        // This allows us to configure stdio with attach handles when they're provided
        let isAttached = (attachStdin || attachStdout || attachStderr) && openStdin
        let shouldDeferCreate = isAttached

        let nativeID: String
        let linuxContainer: LinuxContainer?

        if shouldDeferCreate {
            // Deferred containers: Don't create LinuxContainer yet
            logger.info("Deferring container creation for attached container", metadata: [
                "docker_id": "\(dockerID)",
                "hostname": "\(containerName)"
            ])

            // Store deferred config for later use during start
            deferredConfigs[dockerID] = DeferredContainerConfig(
                image: containerImage,
                command: command,
                env: env,
                workingDir: workingDir,
                hostname: containerName,
                mounts: mounts  // Store mounts for deferred creation
            )

            // Use Docker ID as native ID for deferred containers
            // The actual LinuxContainer will be created during start
            nativeID = dockerID
            linuxContainer = nil
        } else {
            // Non-deferred containers: Create LinuxContainer immediately using helper
            let container = try await createNativeContainer(
                config: NativeContainerConfig(
                    dockerID: dockerID,
                    image: containerImage,
                    command: command,
                    env: env,
                    workingDir: workingDir,
                    hostname: containerName,
                    tty: tty,
                    stdoutWriter: stdoutWriter,
                    stderrWriter: stderrWriter,
                    stdinReader: nil,  // Not attached
                    mounts: mounts
                )
            )

            nativeID = container.id
            linuxContainer = container
        }

        // Store the native container object for later operations (if created)
        if let container = linuxContainer {
            nativeContainers[dockerID] = container
        }

        // Register ID mapping
        registerIDMapping(dockerID: dockerID, nativeID: nativeID)

        // Store container info for state tracking
        let now = Date()
        let containerInfo = ContainerInfo(
            nativeID: nativeID,
            name: containerName,
            image: image,
            imageID: imageID,
            created: now,
            state: "created",
            command: command ?? [],
            path: command?.first ?? "",
            args: command?.dropFirst().map { String($0) } ?? [],
            env: env ?? [],
            workingDir: workingDir ?? "/",
            labels: labels ?? [:],
            ports: [],
            hostConfig: HostConfig(
                binds: binds ?? [],
                networkMode: networkMode ?? "default",
                restartPolicy: restartPolicy ?? RestartPolicy(name: "no", maximumRetryCount: 0)
            ),
            config: ContainerConfiguration(
                hostname: containerName,
                env: env ?? [],
                cmd: command ?? [],
                image: image,
                workingDir: workingDir ?? "",
                labels: labels ?? [:]
            ),
            networkSettings: NetworkSettings(),
            pid: 0,
            exitCode: 0,
            startedAt: nil,
            finishedAt: nil,
            tty: tty,
            needsCreate: shouldDeferCreate,
            networkAttachments: [:]  // Start with no network attachments
        )

        containers[dockerID] = containerInfo

        // Persist container state
        try await persistContainerState(dockerID: dockerID, info: containerInfo)

        logger.info("Container created successfully", metadata: [
            "docker_id": "\(dockerID)",
            "native_id": "\(nativeID)",
            "name": "\(containerName)"
        ])

        return dockerID
    }

    /// Resolve container name or ID to Docker ID
    /// Supports:
    /// - Full 64-char Docker IDs
    /// - Short IDs (minimum 4 chars, prefix matching)
    /// - Container names (with or without "/" prefix)
    public func resolveContainerID(_ nameOrID: String) -> String? {
        // First try direct ID lookup (full 64-char ID)
        if containers[nameOrID] != nil {
            return nameOrID
        }

        // Try short ID prefix matching (4-64 chars)
        if nameOrID.count >= 4 && nameOrID.count < 64 {
            // Check if it's a valid hex string
            let hexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if nameOrID.unicodeScalars.allSatisfy({ hexCharset.contains($0) }) {
                // Find containers with IDs that start with this prefix
                let matches = containers.keys.filter { $0.hasPrefix(nameOrID.lowercased()) }

                if matches.count == 1 {
                    return matches.first
                } else if matches.count > 1 {
                    // Multiple matches - return first (Docker behavior)
                    logger.warning("Multiple containers match short ID", metadata: [
                        "short_id": "\(nameOrID)",
                        "matches": "\(matches.count)"
                    ])
                    return matches.sorted().first
                }
            }
        }

        // Then try name lookup
        for (id, info) in containers {
            if info.name == nameOrID || info.name == "/\(nameOrID)" {
                return id
            }
        }

        return nil
    }

    // MARK: - Container Attach Support

    /// Register attach handles for a container (called before container starts)
    /// Used for interactive containers (docker run -it)
    public func registerAttach(containerID: String, handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation) {
        logger.debug("Registering attach handles", metadata: ["container_id": "\(containerID)"])
        pendingAttaches[containerID] = (handles: handles, exitSignal: exitSignal)
    }

    /// Consume and remove pending attach handles for a container
    /// Returns nil if no attach handles are registered
    private func consumeAttachHandles(containerID: String) -> (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)? {
        return pendingAttaches.removeValue(forKey: containerID)
    }

    // MARK: - Container Lifecycle

    /// Start a container
    public func startContainer(id: String) async throws {
        logger.info("Starting container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Get manager
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Check if this is a deferred container (needs creation)
        let nativeContainer: LinuxContainer
        let attachInfo: (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)?

        if info.needsCreate {
            // Container creation was deferred - create it now
            logger.info("Creating deferred container", metadata: ["id": "\(dockerID)"])

            // Get deferred config
            guard let config = deferredConfigs.removeValue(forKey: dockerID) else {
                logger.error("Deferred config not found", metadata: ["id": "\(dockerID)"])
                throw ContainerManagerError.containerNotFound(id)
            }

            // Check for attach handles
            attachInfo = consumeAttachHandles(containerID: dockerID)

            // Get log writers
            guard let (stdoutLogWriter, stderrLogWriter) = logWriters[dockerID] else {
                logger.error("Log writers not found", metadata: ["id": "\(dockerID)"])
                throw ContainerManagerError.containerNotFound(id)
            }

            // Create stdout/stderr writers (MultiWriter if attached, otherwise just log writers)
            let stdoutWriter: Writer
            let stderrWriter: Writer

            if let attach = attachInfo {
                // Use MultiWriter to send output to both logs AND attach handles
                stdoutWriter = MultiWriter(writers: [stdoutLogWriter, attach.handles.stdout])
                stderrWriter = MultiWriter(writers: [stderrLogWriter, attach.handles.stderr])
                logger.info("Using MultiWriter for attached container", metadata: ["id": "\(dockerID)"])
            } else {
                // No attach - just use log writers
                stdoutWriter = stdoutLogWriter
                stderrWriter = stderrLogWriter
            }

            // Create the LinuxContainer using helper
            let container = try await createNativeContainer(
                config: NativeContainerConfig(
                    dockerID: dockerID,
                    image: config.image,
                    command: config.command,
                    env: config.env,
                    workingDir: config.workingDir,
                    hostname: config.hostname,
                    tty: info.tty,
                    stdoutWriter: stdoutWriter,
                    stderrWriter: stderrWriter,
                    stdinReader: attachInfo?.handles.stdin,  // Include stdin if attached
                    mounts: config.mounts
                )
            )

            // Store the container
            nativeContainers[dockerID] = container
            nativeContainer = container

            // Update needsCreate flag
            info.needsCreate = false
        } else {
            // Container should already be created - check if it exists in framework
            if let container = nativeContainers[dockerID] {
                // Container exists in framework - use it
                nativeContainer = container
                attachInfo = nil

                // Start the container using Containerization API
                // Containerization state machine: .stopped -> create() -> .created -> start() -> .started
                // After a container exits and we call stop(), it goes back to .stopped state
                // To restart, we must call create() again to transition .stopped -> .created
                if info.state == "exited" {
                    logger.info("Container is exited, calling create() before start()", metadata: [
                        "id": "\(dockerID)"
                    ])
                    try await nativeContainer.create()
                }
            } else {
                // Container NOT in framework - must recreate from persisted state
                // This happens after daemon restart: metadata persists but Container objects don't
                logger.info("Recreating container from persisted state", metadata: [
                    "id": "\(dockerID)",
                    "state": "\(info.state)"
                ])

                // Clean up orphaned container storage from previous daemon run
                // The Containerization framework leaves storage directories when the daemon exits
                // We need to remove these before recreating (Docker doesn't preserve writable layer for stopped containers)
                logger.debug("Cleaning up orphaned container storage", metadata: [
                    "id": "\(dockerID)"
                ])
                do {
                    try await manager.delete(dockerID)
                    logger.debug("Cleaned up orphaned storage via manager.delete()", metadata: [
                        "id": "\(dockerID)"
                    ])
                } catch {
                    // Expected to fail if no orphaned storage exists - this is normal
                    logger.debug("No orphaned storage found (this is normal)", metadata: [
                        "id": "\(dockerID)"
                    ])
                }

                // Get the image from persisted config
                logger.debug("Retrieving image for recreation", metadata: [
                    "image": "\(info.image)",
                    "docker_id": "\(dockerID)"
                ])
                let containerImage = try await imageManager.getImage(nameOrId: info.image)

                // Get log writers (create if they don't exist yet)
                let (stdoutLogWriter, stderrLogWriter): (FileLogWriter, FileLogWriter)
                if let existing = logWriters[dockerID] {
                    (stdoutLogWriter, stderrLogWriter) = existing
                } else {
                    let writers = try logManager.createLogWriters(dockerID: dockerID)
                    logWriters[dockerID] = writers
                    (stdoutLogWriter, stderrLogWriter) = writers
                }

                // Parse volume mounts from persisted binds
                let recreatedMounts = try parseBindMounts(info.hostConfig.binds)

                // Recreate the LinuxContainer with the persisted configuration
                let container = try await createNativeContainer(
                    config: NativeContainerConfig(
                        dockerID: dockerID,
                        image: containerImage,
                        command: info.command,
                        env: info.env,
                        workingDir: info.workingDir,
                        hostname: info.config.hostname,
                        tty: info.tty,
                        stdoutWriter: stdoutLogWriter,
                        stderrWriter: stderrLogWriter,
                        stdinReader: nil,  // No stdin for recreated containers
                        mounts: recreatedMounts
                    )
                )

                // Store the recreated container
                nativeContainers[dockerID] = container
                nativeContainer = container
                attachInfo = nil

                logger.info("Container recreated successfully from persisted state", metadata: [
                    "id": "\(dockerID)"
                ])

                // Container is now in .created state (createNativeContainer calls .create())
                // Ready to be started
            }
        }

        logger.info("Starting container with Containerization API", metadata: [
            "id": "\(dockerID)",
            "current_state": "\(info.state)"
        ])
        try await nativeContainer.start()

        // Update state
        info.state = "running"
        info.startedAt = Date()
        info.pid = 1  // Containers run as PID 1 in their VM
        containers[dockerID] = info

        // Persist state change
        try await persistContainerState(dockerID: dockerID, info: info)

        logger.info("Container started successfully", metadata: [
            "id": "\(dockerID)",
            "state": "running"
        ])

        // Auto-attach to network based on networkMode if no networks are attached
        // Docker CLI sets networkMode in HostConfig and expects the daemon to handle attachment
        if let networkManager = networkManager,
           info.networkAttachments.isEmpty {
            let networkMode = info.hostConfig.networkMode

            // Only auto-attach if networkMode is not "none"
            if networkMode != "none" {
                // Normalize networkMode: empty, "default", or "bridge" all mean the default bridge network
                let targetNetwork: String
                if networkMode.isEmpty || networkMode == "default" {
                    targetNetwork = "bridge"
                } else {
                    targetNetwork = networkMode
                }

                logger.info("Auto-attaching container to network", metadata: [
                    "container": "\(dockerID)",
                    "network": "\(targetNetwork)",
                    "networkMode": "\(networkMode)"
                ])

                do {
                    // Resolve network name/ID to actual network ID
                    guard let resolvedNetworkID = await networkManager.resolveNetworkID(targetNetwork) else {
                        logger.warning("Failed to resolve network", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(targetNetwork)"
                        ])
                        return  // Skip network attachment if network doesn't exist
                    }

                    let containerName = info.name ?? String(dockerID.prefix(12))
                    let attachment = try await networkManager.attachContainerToNetwork(
                        containerID: dockerID,
                        container: nativeContainer,
                        networkID: resolvedNetworkID,
                        containerName: containerName,
                        aliases: []
                    )

                    // Record the attachment in ContainerManager
                    try await self.attachContainerToNetwork(
                        dockerID: dockerID,
                        networkID: resolvedNetworkID,
                        ip: attachment.ip,
                        mac: attachment.mac,
                        aliases: attachment.aliases
                    )

                    logger.info("Container auto-attached to network successfully", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(targetNetwork)",
                        "resolved_id": "\(resolvedNetworkID)",
                        "ip": "\(attachment.ip)"
                    ])
                } catch {
                    // Log the error but don't fail the container start
                    // Networking is optional - container can run without it
                    logger.warning("Failed to auto-attach container to network", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(targetNetwork)",
                        "error": "\(error)"
                    ])
                }
            } else {
                logger.debug("Container networkMode is 'none', skipping auto-attachment", metadata: [
                    "container": "\(dockerID)"
                ])
            }
        }

        // Push DNS topology to this container (for its own resolution)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all other containers on the same networks (to add this container)
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        // Spawn background monitoring task to detect when container exits
        // The task waits for the container to exit, then calls back into the actor to update state
        let monitoringTask = Task { [weak self, logger, attachInfo] in
            do {
                logger.debug("Background monitor: waiting for container to exit", metadata: ["id": "\(dockerID)"])
                let exitStatus = try await nativeContainer.wait(timeoutInSeconds: nil)

                logger.info("Background monitor: container exited", metadata: [
                    "id": "\(dockerID)",
                    "exit_code": "\(exitStatus.exitCode)"
                ])

                // Signal exit to attach connection if present
                if let attach = attachInfo {
                    logger.debug("Signaling exit to attach connection", metadata: ["id": "\(dockerID)"])

                    // Close stdout/stderr writers to finish the stream continuations
                    try? attach.handles.stdout.close()
                    try? attach.handles.stderr.close()

                    // Signal exit
                    attach.exitSignal.yield(())
                    attach.exitSignal.finish()
                }

                // After wait() completes, we MUST call stop() to clean up the VM
                // and transition the container from .started to .stopped state
                // Reference: containerization/examples/ctr-example/main.swift
                logger.debug("Background monitor: stopping container to clean up VM", metadata: ["id": "\(dockerID)"])
                try await nativeContainer.stop()

                // Update container state via actor-isolated method
                await self?.updateContainerStateAfterExit(
                    dockerID: dockerID,
                    exitCode: Int(exitStatus.exitCode)
                )
            } catch {
                logger.warning("Background monitor: error waiting for container", metadata: [
                    "id": "\(dockerID)",
                    "error": "\(error)"
                ])

                // Signal exit to attach connection even on error
                if let attach = attachInfo {
                    // Close stdout/stderr writers to finish the stream continuations
                    try? attach.handles.stdout.close()
                    try? attach.handles.stderr.close()

                    // Signal exit
                    attach.exitSignal.yield(())
                    attach.exitSignal.finish()
                }

                await self?.cleanupMonitoringTask(dockerID: dockerID)
            }
        }

        monitoringTasks[dockerID] = monitoringTask
    }

    /// Stop a container
    public func stopContainer(id: String, timeout: Int? = nil) async throws {
        logger.info("Stopping container", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

        // Cancel monitoring task if running
        if let task = monitoringTasks.removeValue(forKey: dockerID) {
            task.cancel()
        }

        // Stop the container using Containerization API
        logger.info("Stopping container with Containerization API", metadata: ["id": "\(dockerID)"])
        try await nativeContainer.stop()

        // Push DNS topology updates to remove this container from other containers' view
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        // Update state
        info.state = "exited"
        info.finishedAt = Date()
        info.exitCode = 0
        info.pid = 0
        containers[dockerID] = info

        // Persist state change (mark as stopped by user)
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: true)

        logger.info("Container stopped successfully", metadata: [
            "id": "\(dockerID)",
            "state": "exited"
        ])
    }

    /// Remove a container
    public func removeContainer(id: String, force: Bool = false, removeVolumes: Bool = false) async throws {
        logger.info("Removing container", metadata: [
            "id": "\(id)",
            "force": "\(force)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Check if container is running and force is not set
        if info.state == "running" && !force {
            throw ContainerManagerError.containerRunning(id)
        }

        // Check if the native container object exists
        // After daemon restart, this will be nil even though metadata persists
        if let nativeContainer = nativeContainers[dockerID] {
            // Container exists in framework - stop it before removal
            logger.debug("Native container exists, stopping before removal", metadata: ["id": "\(dockerID)"])

            // CRITICAL: Stop the container FIRST before waiting for monitoring task
            // This avoids deadlock where monitoring task is waiting for container to exit
            // and we're waiting for monitoring task to finish
            if info.state == "running" || info.state == "created" {
                if force || info.state == "created" {
                    logger.info("Stopping container before removal", metadata: [
                        "id": "\(dockerID)",
                        "state": "\(info.state)"
                    ])
                    try? await nativeContainer.stop()
                } else if !force && info.state == "running" {
                    // Already checked above, but being explicit
                    throw ContainerManagerError.containerRunning(id)
                }
            }

            // Cancel monitoring task if running and wait for it to complete
            // Safe to wait now since we've already stopped the container above
            if let task = monitoringTasks.removeValue(forKey: dockerID) {
                task.cancel()
                // Wait for the task to fully complete to avoid file descriptor races
                _ = await task.result
            }

            // For exited containers, still call stop() to ensure cleanup
            if info.state == "exited" {
                logger.debug("Calling stop() on exited container for cleanup", metadata: ["id": "\(dockerID)"])
                try? await nativeContainer.stop()
            }
        } else {
            // Container NOT in framework - only exists in database (persisted state)
            // This happens after daemon restart when container was never recreated
            logger.info("Removing database-only container (not in framework)", metadata: [
                "id": "\(dockerID)",
                "state": "\(info.state)"
            ])

            // No need to stop native container since it doesn't exist
            // Just clean up any monitoring tasks
            if let task = monitoringTasks.removeValue(forKey: dockerID) {
                task.cancel()
                _ = await task.result
            }
        }

        // Push DNS topology updates to remove this container from other containers' view
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        logger.info("Removing container from tracking", metadata: ["id": "\(dockerID)"])

        // Clean up all state
        nativeContainers.removeValue(forKey: dockerID)
        if let nativeID = idMapping[dockerID] {
            reverseMapping.removeValue(forKey: nativeID)
        }
        idMapping.removeValue(forKey: dockerID)
        containers.removeValue(forKey: dockerID)

        // Delete from persistent storage
        try await stateStore.deleteContainer(id: dockerID)

        // Close and remove log files
        if let (stdoutWriter, stderrWriter) = logWriters.removeValue(forKey: dockerID) {
            try? stdoutWriter.close()
            try? stderrWriter.close()
        }
        try? logManager.removeLogs(dockerID: dockerID)

        logger.info("Container removed successfully", metadata: [
            "id": "\(dockerID)"
        ])
    }

    /// Wait for a container to exit
    public func waitContainer(id: String, timeout: Int64? = nil) async throws -> Int {
        logger.info("Waiting for container to exit", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // If container is already exited, return the exit code immediately
        if info.state == "exited" {
            logger.info("Container already exited", metadata: [
                "id": "\(dockerID)",
                "exit_code": "\(info.exitCode)"
            ])
            return info.exitCode
        }

        // If container is in created state, Docker CLI expects us to wait for it to finish
        // But the Containerization API wait() requires the container to be running
        // So we return 0 immediately for created containers (they haven't run yet)
        if info.state == "created" {
            logger.debug("Container in created state, returning 0", metadata: ["id": "\(dockerID)"])
            return 0
        }

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

        // Wait for the container process to exit
        let exitStatus = try await nativeContainer.wait(timeoutInSeconds: timeout)

        // Update container state to exited
        info.state = "exited"
        info.exitCode = Int(exitStatus.exitCode)
        info.finishedAt = Date()
        info.pid = 0
        containers[dockerID] = info

        // Persist container state (not stopped by user - this was a natural exit from wait)
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: false)

        logger.info("Container exited", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitStatus.exitCode)"
        ])

        return Int(exitStatus.exitCode)
    }

    // MARK: - Background Monitoring Helpers

    /// Update container state after it exits (called by background monitoring task)
    private func updateContainerStateAfterExit(dockerID: String, exitCode: Int) async {
        guard var containerInfo = containers[dockerID] else {
            logger.warning("Container not found when updating exit state", metadata: ["id": "\(dockerID)"])
            return
        }

        containerInfo.state = "exited"
        containerInfo.exitCode = exitCode
        containerInfo.finishedAt = Date()
        containerInfo.pid = 0
        containers[dockerID] = containerInfo

        // Persist container state (not stopped by user - this was a natural exit)
        do {
            try await persistContainerState(dockerID: dockerID, info: containerInfo, stoppedByUser: false)
        } catch {
            logger.error("Failed to persist container exit state", metadata: [
                "id": "\(dockerID)",
                "error": "\(error)"
            ])
        }

        // Clean up monitoring task
        monitoringTasks.removeValue(forKey: dockerID)

        logger.debug("Container state updated after exit", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitCode)"
        ])

        // Check restart policy and restart if needed
        await handleRestartPolicy(dockerID: dockerID, exitCode: exitCode, stoppedByUser: false)
    }

    /// Handle restart policy for a container that has exited
    private func handleRestartPolicy(dockerID: String, exitCode: Int, stoppedByUser: Bool) async {
        guard let containerInfo = containers[dockerID] else {
            return
        }

        let policy = containerInfo.hostConfig.restartPolicy

        // Determine if container should restart based on policy
        let shouldRestart: Bool
        switch policy.name {
        case "always":
            shouldRestart = true
        case "unless-stopped":
            shouldRestart = !stoppedByUser
        case "on-failure":
            shouldRestart = exitCode != 0
        default:
            shouldRestart = false
        }

        if shouldRestart {
            logger.info("Container will be restarted per restart policy", metadata: [
                "id": "\(dockerID)",
                "name": "\(containerInfo.name ?? dockerID)",
                "policy": "\(policy.name)",
                "exit_code": "\(exitCode)",
                "stopped_by_user": "\(stoppedByUser)"
            ])

            // Add a small delay before restarting to avoid rapid restart loops
            try? await Task.sleep(for: .seconds(1))

            do {
                try await startContainer(id: dockerID)
                logger.info("Container restarted successfully", metadata: [
                    "id": "\(dockerID)",
                    "name": "\(containerInfo.name ?? dockerID)"
                ])
            } catch {
                logger.error("Failed to restart container", metadata: [
                    "id": "\(dockerID)",
                    "name": "\(containerInfo.name ?? dockerID)",
                    "error": "\(error)"
                ])
            }
        } else {
            logger.debug("Container will NOT be restarted", metadata: [
                "id": "\(dockerID)",
                "policy": "\(policy.name)",
                "exit_code": "\(exitCode)",
                "stopped_by_user": "\(stoppedByUser)"
            ])
        }
    }

    /// Clean up monitoring task (called when monitoring fails)
    private func cleanupMonitoringTask(dockerID: String) {
        monitoringTasks.removeValue(forKey: dockerID)
    }

    // MARK: - Log Management

    /// Get log paths for a container
    nonisolated public func getLogPaths(dockerID: String) -> ContainerLogManager.LogPaths? {
        return logManager.getLogPaths(dockerID: dockerID)
    }

    // MARK: - Network Operations

    /// Attach a container to a network
    /// This method is called by NetworkManager after allocating IP and creating the attachment
    /// If the container is running, it will be stopped, reconfigured, and restarted
    public func attachContainerToNetwork(
        dockerID: String,
        networkID: String,
        ip: String,
        mac: String,
        aliases: [String]
    ) async throws {
        guard var containerInfo = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        logger.info("Attaching container to network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)",
            "ip": "\(ip)",
            "mac": "\(mac)"
        ])

        // Store network attachment
        let attachment = NetworkAttachment(
            networkID: networkID,
            ip: ip,
            mac: mac,
            aliases: aliases
        )
        containerInfo.networkAttachments[networkID] = attachment
        containers[dockerID] = containerInfo

        // Persist network attachment
        try await stateStore.saveNetworkAttachment(
            containerID: dockerID,
            networkID: networkID,
            ipAddress: ip,
            macAddress: mac,
            aliases: aliases
        )

        // With TAP-over-vsock architecture, no container recreation needed
        // TAP devices are created dynamically via NetworkBridge.attachContainerToNetwork

        logger.info("Container attached to network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Push DNS topology to this container (to add new network's peers)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all containers on this network (to add this container)
        await pushDNSTopologyToNetwork(networkID: networkID)
    }

    /// Detach a container from a network
    /// This method is called by NetworkManager before releasing the IP
    public func detachContainerFromNetwork(
        dockerID: String,
        networkID: String
    ) async throws {
        guard var containerInfo = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        logger.info("Detaching container from network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Remove network attachment
        containerInfo.networkAttachments.removeValue(forKey: networkID)
        containers[dockerID] = containerInfo

        // Persist network detachment
        try await stateStore.deleteNetworkAttachment(
            containerID: dockerID,
            networkID: networkID
        )

        // If container is running, we would need to hot-unplug the network interface
        // For now, network changes require container restart
        // TODO: Implement hot-unplug if Apple Containerization supports it

        logger.info("Container detached from network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Push DNS topology to this container (to remove detached network's peers)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all containers on this network (to remove this container)
        await pushDNSTopologyToNetwork(networkID: networkID)
    }

    /// Get network attachments for a container
    public func getNetworkAttachments(dockerID: String) async -> [String: NetworkAttachment] {
        return containers[dockerID]?.networkAttachments ?? [:]
    }

    /// Get container name by Docker ID
    public func getContainerName(dockerID: String) async -> String? {
        return containers[dockerID]?.name
    }

    // MARK: - Helpers for ExecManager

    /// Get container state by ID (for checking if container is running)
    public func getContainerState(id: String) async -> String? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return containers[dockerID]?.state
    }

    /// Check if container is running (for log streaming)
    public func isContainerRunning(dockerID: String) async -> Bool {
        return containers[dockerID]?.state == "running"
    }

    /// Get native container instance by ID (for exec operations)
    public func getNativeContainer(id: String) async -> LinuxContainer? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return nativeContainers[dockerID]
    }

    /// Get LinuxContainer instance by Docker ID (for network operations)
    /// This is an alias for getNativeContainer but with a clearer name for networking context
    public func getLinuxContainer(dockerID: String) async throws -> LinuxContainer? {
        guard containers[dockerID] != nil else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }
        return nativeContainers[dockerID]
    }

    // MARK: - Volume/Mount Helpers

    /// Parse Docker bind mount strings into Containerization.Mount objects
    /// Format: "/host/path:/container/path[:ro]"
    private func parseBindMounts(_ binds: [String]?) throws -> [Containerization.Mount] {
        guard let binds = binds else {
            return []
        }

        var mounts: [Containerization.Mount] = []

        for bind in binds {
            let parts = bind.split(separator: ":")
            guard parts.count >= 2 else {
                logger.warning("Invalid bind mount format, skipping", metadata: ["bind": "\(bind)"])
                continue
            }

            let hostPath = String(parts[0])
            let containerPath = String(parts[1])
            let isReadOnly = parts.count >= 3 && parts[2] == "ro"

            // Expand tilde in host path
            let expandedHostPath = NSString(string: hostPath).expandingTildeInPath

            // Validate host path exists (create directory if it doesn't exist for rw mounts)
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: expandedHostPath, isDirectory: &isDirectory)

            if !exists && !isReadOnly {
                // For read-write mounts, create the directory if it doesn't exist
                logger.info("Creating host directory for volume mount", metadata: [
                    "path": "\(expandedHostPath)"
                ])
                try fileManager.createDirectory(
                    atPath: expandedHostPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } else if !exists && isReadOnly {
                logger.error("Read-only bind mount source does not exist", metadata: [
                    "path": "\(expandedHostPath)"
                ])
                throw ContainerManagerError.volumeSourceNotFound(expandedHostPath)
            }

            // Create mount options
            var options: [String] = []
            if isReadOnly {
                options.append("ro")
            }

            // Create the Mount using the host path as source
            // The Containerization framework will:
            // 1. Use the host path to create the VirtioFS shared directory
            // 2. Hash the path to generate the device tag
            // 3. Transform to AttachedFilesystem with the hashed tag as source (for vminitd)
            let mount = Containerization.Mount.share(
                source: expandedHostPath,
                destination: containerPath,
                options: options
            )

            mounts.append(mount)

            logger.debug("Parsed bind mount", metadata: [
                "source": "\(expandedHostPath)",
                "destination": "\(containerPath)",
                "readOnly": "\(isReadOnly)"
            ])
        }

        return mounts
    }

    // MARK: - ID Mapping

    /// Generate a Docker-compatible 64-character hex ID
    private func generateDockerID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Docker IDs are 64 chars, so double the UUID
        return (uuid + uuid).prefix(64).lowercased()
    }

    /// Register bidirectional ID mapping
    private func registerIDMapping(dockerID: String, nativeID: String) {
        idMapping[dockerID] = nativeID
        reverseMapping[nativeID] = dockerID
    }

    /// Get Docker ID from native ID
    private func getDockerID(for nativeID: String) -> String {
        if let dockerID = reverseMapping[nativeID] {
            return dockerID
        }

        // Create new mapping if needed
        let dockerID = generateDockerID()
        registerIDMapping(dockerID: dockerID, nativeID: nativeID)
        return dockerID
    }

    /// Generate a random container name (Docker-style)
    private func generateContainerName() -> String {
        let adjectives = ["happy", "silly", "brave", "clever", "zen", "epic"]
        let nouns = ["cat", "dog", "bird", "fish", "lion", "tiger"]
        let adj = adjectives.randomElement() ?? "random"
        let noun = nouns.randomElement() ?? "container"
        return "\(adj)_\(noun)"
    }

    // MARK: - Helper Methods

    /// Format status string from container state
    private func formatStatusFromState(_ info: ContainerInfo) -> String {
        switch info.state {
        case "running":
            if let startedAt = info.startedAt {
                let duration = Date().timeIntervalSince(startedAt)
                return "Up \(formatDuration(duration))"
            }
            return "Up"
        case "exited":
            if let finishedAt = info.finishedAt {
                let duration = Date().timeIntervalSince(finishedAt)
                return "Exited (\(info.exitCode)) \(formatDuration(duration)) ago"
            }
            return "Exited (\(info.exitCode))"
        case "created":
            return "Created"
        default:
            return info.state.capitalized
        }
    }

    /// Format duration for status string
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs < 60 {
            return "\(secs) seconds"
        } else if secs < 3600 {
            return "\(secs / 60) minutes"
        } else if secs < 86400 {
            return "\(secs / 3600) hours"
        } else {
            return "\(secs / 86400) days"
        }
    }

    /// Persist container state to SQLite database
    /// This helper method serializes ContainerInfo and saves it to StateStore
    private func persistContainerState(
        dockerID: String,
        info: ContainerInfo,
        stoppedByUser: Bool = false
    ) async throws {
        // Encode configuration as JSON
        let configData = try JSONEncoder().encode(info.config)
        let configJSON = String(data: configData, encoding: .utf8) ?? "{}"

        let hostConfigData = try JSONEncoder().encode(info.hostConfig)
        let hostConfigJSON = String(data: hostConfigData, encoding: .utf8) ?? "{}"

        // Save container to database
        try await stateStore.saveContainer(
            id: dockerID,
            name: info.name ?? "unknown",
            image: info.image,
            imageID: info.imageID,
            createdAt: info.created,
            status: info.state,
            running: info.state == "running",
            paused: info.state == "paused",
            restarting: info.state == "restarting",
            pid: info.pid,
            exitCode: info.exitCode,
            startedAt: info.startedAt,
            finishedAt: info.finishedAt,
            stoppedByUser: stoppedByUser,
            configJSON: configJSON,
            hostConfigJSON: hostConfigJSON
        )

        // Save network attachments
        for (networkID, attachment) in info.networkAttachments {
            try await stateStore.saveNetworkAttachment(
                containerID: dockerID,
                networkID: networkID,
                ipAddress: attachment.ip,
                macAddress: attachment.mac,
                aliases: attachment.aliases
            )
        }

        logger.debug("Persisted container state", metadata: [
            "container": "\(dockerID)",
            "state": "\(info.state)",
            "networkCount": "\(info.networkAttachments.count)"
        ])
    }

    // MARK: - DNS Topology Publisher

    /// Push DNS topology update to a specific container
    /// Called when network topology changes (container start/stop/attach/detach)
    private func pushDNSTopologyUpdate(to dockerID: String) async {
        // Get container info
        guard let containerInfo = containers[dockerID] else {
            logger.warning("Cannot push DNS topology: container not found", metadata: [
                "container": "\(dockerID)"
            ])
            return
        }

        // Only push to running containers
        guard containerInfo.state == "running" else {
            logger.debug("Skipping DNS push: container not running", metadata: [
                "container": "\(dockerID)",
                "state": "\(containerInfo.state)"
            ])
            return
        }

        // Get native container
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.warning("Cannot push DNS topology: native container not found", metadata: [
                "container": "\(dockerID)"
            ])
            return
        }

        // Build topology snapshot for this container's networks
        let networkAttachments = containerInfo.networkAttachments
        guard !networkAttachments.isEmpty else {
            logger.debug("Skipping DNS push: container has no network attachments", metadata: [
                "container": "\(dockerID)"
            ])
            return
        }

        // Build protobuf mappings
        var mappings: [String: Arca_Tapforwarder_V1_NetworkPeers] = [:]

        for (networkID, _) in networkAttachments {
            // Get network name from NetworkManager
            guard let networkManager = networkManager else {
                logger.warning("Cannot build topology: NetworkManager not available")
                continue
            }

            guard let networkName = await networkManager.getNetworkName(networkID: networkID) else {
                logger.warning("Cannot build topology: network name not found", metadata: [
                    "network_id": "\(networkID)"
                ])
                continue
            }

            // Get all containers on this network
            let containersOnNetwork = await getContainersOnNetwork(networkID: networkID)

            // Build NetworkPeers
            var peers = Arca_Tapforwarder_V1_NetworkPeers()
            peers.containers = containersOnNetwork.map { peer in
                var dnsInfo = Arca_Tapforwarder_V1_ContainerDNSInfo()
                dnsInfo.name = peer.name
                dnsInfo.id = peer.dockerID
                dnsInfo.ipAddress = peer.ipAddress
                dnsInfo.aliases = peer.aliases
                return dnsInfo
            }

            mappings[networkName] = peers
        }

        // Check if we have any mappings to push
        guard !mappings.isEmpty else {
            logger.warning("Skipping DNS push: no network mappings built", metadata: [
                "container": "\(dockerID)",
                "networkAttachments": "\(networkAttachments.count)",
                "hasNetworkManager": "\(networkManager != nil)"
            ])
            return
        }

        logger.debug("Building DNS topology push", metadata: [
            "container": "\(dockerID)",
            "networks": "\(mappings.keys.joined(separator: ", "))",
            "totalPeers": "\(mappings.values.map { $0.containers.count }.reduce(0, +))"
        ])

        // Dial container and push topology
        do {
            let client = try await TAPForwarderClient(
                container: nativeContainer,
                logger: logger
            )

            let response = try await client.updateDNSMappings(networks: mappings)

            // Close client before processing response
            await client.close()

            if response.success {
                logger.info("DNS topology pushed successfully", metadata: [
                    "container": "\(dockerID)",
                    "networks": "\(mappings.keys.joined(separator: ", "))",
                    "records": "\(response.recordsUpdated)"
                ])
            } else {
                logger.error("DNS topology push failed", metadata: [
                    "container": "\(dockerID)",
                    "error": "\(response.error)"
                ])
            }
        } catch {
            logger.error("Failed to push DNS topology", metadata: [
                "container": "\(dockerID)",
                "error": "\(error)"
            ])
        }
    }

    /// Push DNS topology updates to all containers on a specific network
    /// Called when a container joins/leaves a network or starts/stops
    private func pushDNSTopologyToNetwork(networkID: String) async {
        logger.debug("Pushing DNS topology to all containers on network", metadata: [
            "network_id": "\(networkID)"
        ])

        // Get all running containers on this network
        let containersOnNetwork = containers.values.filter { containerInfo in
            containerInfo.state == "running" &&
            containerInfo.networkAttachments.keys.contains(networkID)
        }

        logger.debug("Found containers on network", metadata: [
            "network_id": "\(networkID)",
            "count": "\(containersOnNetwork.count)"
        ])

        // Push to each container
        for containerInfo in containersOnNetwork {
            // Find Docker ID for this container
            if let dockerID = containers.first(where: { $0.value.nativeID == containerInfo.nativeID })?.key {
                await pushDNSTopologyUpdate(to: dockerID)
            }
        }
    }

    /// Helper to get all containers on a specific network
    private func getContainersOnNetwork(networkID: String) async -> [ContainerDNSPeer] {
        var peers: [ContainerDNSPeer] = []

        for (dockerID, containerInfo) in containers {
            // Only include running containers
            guard containerInfo.state == "running" else {
                continue
            }

            // Check if container is on this network
            guard let attachment = containerInfo.networkAttachments[networkID] else {
                continue
            }

            // Get container name (use short ID if no name)
            let containerName = containerInfo.name ?? String(dockerID.prefix(12))

            peers.append(ContainerDNSPeer(
                name: containerName,
                dockerID: dockerID,
                ipAddress: attachment.ip,
                aliases: attachment.aliases
            ))
        }

        return peers
    }

    /// Container DNS information for building topology snapshots
    private struct ContainerDNSPeer {
        let name: String
        let dockerID: String
        let ipAddress: String
        let aliases: [String]
    }

    // MARK: - Helper Types

    /// Internal container tracking info
    private struct ContainerInfo {
        let nativeID: String
        let name: String?
        let image: String
        let imageID: String
        let created: Date
        var state: String
        let command: [String]
        let path: String
        let args: [String]
        let env: [String]
        let workingDir: String
        let labels: [String: String]
        let ports: [PortMapping]
        let hostConfig: HostConfig
        let config: ContainerConfiguration
        let networkSettings: NetworkSettings
        var pid: Int
        var exitCode: Int
        var startedAt: Date?
        var finishedAt: Date?
        let tty: Bool  // Whether container was created with TTY
        var needsCreate: Bool  // Whether .create() was deferred (for attached containers)
        var networkAttachments: [String: NetworkAttachment]  // Network ID -> Attachment details
    }

    /// Network attachment details for a container
    public struct NetworkAttachment: Sendable {
        public let networkID: String
        public let ip: String
        public let mac: String
        public let aliases: [String]

        public init(networkID: String, ip: String, mac: String, aliases: [String]) {
            self.networkID = networkID
            self.ip = ip
            self.mac = mac
            self.aliases = aliases
        }
    }

}

// MARK: - Errors

public enum ContainerManagerError: Error, CustomStringConvertible {
    case notInitialized
    case notImplemented
    case missingKernel
    case kernelNotFound(String)
    case containerNotFound(String)
    case containerRunning(String)
    case imageNotFound(String)
    case invalidConfiguration(String)
    case volumeSourceNotFound(String)

    public var description: String {
        switch self {
        case .notInitialized:
            return "ContainerManager not initialized"
        case .notImplemented:
            return "Feature not yet implemented (Containerization API integration in progress)"
        case .missingKernel:
            return "Kernel path not specified"
        case .kernelNotFound(let path):
            return "Kernel file not found at: \(path)\nPlease run: arca setup"
        case .containerNotFound(let id):
            return "No such container: \(id)"
        case .containerRunning(let id):
            return "Container is running: \(id). Stop the container before removing it or use force."
        case .imageNotFound(let ref):
            return "No such image: \(ref)"
        case .invalidConfiguration(let msg):
            return "Invalid configuration: \(msg)"
        case .volumeSourceNotFound(let path):
            return "Volume source path does not exist: \(path)"
        }
    }
}

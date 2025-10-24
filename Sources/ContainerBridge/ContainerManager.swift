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

    /// Configuration for a container whose .create() was deferred
    private struct DeferredContainerConfig {
        let image: Containerization.Image
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
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

    public init(imageManager: ImageManager, kernelPath: String, logger: Logger) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.logger = logger
        self.logManager = ContainerLogManager(logger: logger)
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
        // This will pull the vminit image if not already present
        nativeManager = try await Containerization.ContainerManager(
            kernel: kernel,
            initfsReference: "vminit:latest"
        )

        logger.info("ContainerManager initialized successfully")
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

        // List containers from our internal state tracking
        // Background monitoring tasks automatically update state when containers exit
        return containers.values.compactMap { info -> ContainerSummary? in
            // Filter by state if not showing all
            if !all && info.state != "running" {
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
        networkMode: String? = nil
    ) async throws -> String {
        logger.info("Creating container", metadata: [
            "image": "\(image)",
            "name": "\(name ?? "auto")",
            "attach": "\(attachStdin || attachStdout || attachStderr)",
            "tty": "\(tty)"
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
                hostname: containerName
            )

            // Use Docker ID as native ID for deferred containers
            // The actual LinuxContainer will be created during start
            nativeID = dockerID
            linuxContainer = nil
        } else {
            // Non-deferred containers: Create LinuxContainer immediately
            logger.info("Creating container with Containerization API", metadata: [
                "docker_id": "\(dockerID)",
                "hostname": "\(containerName)"
            ])

            let container = try await manager.create(
                dockerID,
                image: containerImage,
                rootfsSizeInBytes: 8 * 1024 * 1024 * 1024  // 8 GB
            ) { @Sendable config in
                // Configure the container process (OCI-compliant)
                // Note: config.process is already initialized from image config via init(from:)

                // Override with Docker API parameters if provided
                if let command = command {
                    config.process.arguments = command
                }

                if let env = env {
                    // Merge with existing env from image, Docker CLI behavior
                    config.process.environmentVariables += env
                }

                if let workingDir = workingDir {
                    config.process.workingDirectory = workingDir
                }

                // Set hostname (OCI spec field)
                config.hostname = containerName

                // Inject arca-tap-forwarder binary via bind mount for networking
                // Mount the entire ~/.arca/bin directory to /.arca/bin in the container
                // This makes the binary available at /.arca/bin/arca-tap-forwarder
                let arcaBinPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".arca/bin")
                    .path

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: arcaBinPath, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    config.mounts.append(
                        .share(
                            source: arcaBinPath,
                            destination: "/.arca/bin",
                            options: ["ro"]
                        )
                    )
                    logger.debug("Bind mounted arca bin directory", metadata: [
                        "source": "\(arcaBinPath)",
                        "destination": "/.arca/bin"
                    ])
                }

                // Configure TTY mode
                config.process.terminal = tty

                // Configure stdout to write to log files (always needed)
                config.process.stdout = stdoutWriter

                // Configure stderr (only when NOT using TTY - TTY merges stderr into stdout)
                if !tty {
                    config.process.stderr = stderrWriter
                }
            }

            nativeID = container.id
            linuxContainer = container

            // Call .create() to set up the VM
            logger.info("Setting up container VM and runtime environment", metadata: [
                "docker_id": "\(dockerID)",
                "native_id": "\(nativeID)"
            ])
            try await container.create()
            logger.info("Container VM created successfully", metadata: ["docker_id": "\(dockerID)"])
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
            hostConfig: HostConfig(networkMode: networkMode ?? "default"),
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

            // Create the LinuxContainer with proper stdio configuration
            let container = try await manager.create(
                dockerID,
                image: config.image,
                rootfsSizeInBytes: 8 * 1024 * 1024 * 1024  // 8 GB
            ) { containerConfig in
                // Override with Docker API parameters
                if let command = config.command {
                    containerConfig.process.arguments = command
                }

                if let env = config.env {
                    // Merge with existing env from image
                    containerConfig.process.environmentVariables += env
                }

                if let workingDir = config.workingDir {
                    containerConfig.process.workingDirectory = workingDir
                }

                // Set hostname
                containerConfig.hostname = config.hostname

                // Configure TTY mode
                containerConfig.process.terminal = info.tty

                // Configure stdout (always needed)
                containerConfig.process.stdout = stdoutWriter

                // Configure stderr (only when NOT using TTY - TTY merges stderr into stdout)
                if !info.tty {
                    containerConfig.process.stderr = stderrWriter
                }

                // Configure stdin if attached
                if let attach = attachInfo {
                    containerConfig.process.stdin = attach.handles.stdin
                }
            }

            // Call .create() to set up the VM
            logger.info("Setting up container VM and runtime environment", metadata: ["id": "\(dockerID)"])
            try await container.create()
            logger.info("Container VM created successfully", metadata: ["id": "\(dockerID)"])

            // Store the container
            nativeContainers[dockerID] = container
            nativeContainer = container

            // Update needsCreate flag
            info.needsCreate = false
        } else {
            // Container already created - get it
            guard let container = nativeContainers[dockerID] else {
                logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
                throw ContainerManagerError.containerNotFound(id)
            }
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
                    let containerName = info.name ?? String(dockerID.prefix(12))
                    _ = try await networkManager.connectContainer(
                        containerID: dockerID,
                        containerName: containerName,
                        networkID: targetNetwork,
                        ipv4Address: nil,
                        aliases: []
                    )
                    logger.info("Container auto-attached to network successfully", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(targetNetwork)"
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

        // Update state
        info.state = "exited"
        info.finishedAt = Date()
        info.exitCode = 0
        info.pid = 0
        containers[dockerID] = info

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

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

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

        logger.info("Removing container from tracking", metadata: ["id": "\(dockerID)"])

        // Clean up all state
        nativeContainers.removeValue(forKey: dockerID)
        if let nativeID = idMapping[dockerID] {
            reverseMapping.removeValue(forKey: nativeID)
        }
        idMapping.removeValue(forKey: dockerID)
        containers.removeValue(forKey: dockerID)

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

        logger.info("Container exited", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitStatus.exitCode)"
        ])

        return Int(exitStatus.exitCode)
    }

    // MARK: - Background Monitoring Helpers

    /// Update container state after it exits (called by background monitoring task)
    private func updateContainerStateAfterExit(dockerID: String, exitCode: Int) {
        guard var containerInfo = containers[dockerID] else {
            logger.warning("Container not found when updating exit state", metadata: ["id": "\(dockerID)"])
            return
        }

        containerInfo.state = "exited"
        containerInfo.exitCode = exitCode
        containerInfo.finishedAt = Date()
        containerInfo.pid = 0
        containers[dockerID] = containerInfo

        // Clean up monitoring task
        monitoringTasks.removeValue(forKey: dockerID)

        logger.debug("Container state updated after exit", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitCode)"
        ])
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

        // With TAP-over-vsock architecture, no container recreation needed
        // TAP devices are created dynamically via NetworkBridge.attachContainerToNetwork

        logger.info("Container attached to network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])
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

        // If container is running, we would need to hot-unplug the network interface
        // For now, network changes require container restart
        // TODO: Implement hot-unplug if Apple Containerization supports it

        logger.info("Container detached from network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])
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
        }
    }
}

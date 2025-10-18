import Foundation
import Logging
import Containerization
import ContainerizationOCI

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

    private var nativeManager: Containerization.ContainerManager?

    public init(imageManager: ImageManager, kernelPath: String, logger: Logger) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.logger = logger
        self.logManager = ContainerLogManager(logger: logger)
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
        labels: [String: String]?
    ) async throws -> String {
        logger.info("Creating container", metadata: [
            "image": "\(image)",
            "name": "\(name ?? "auto")"
        ])

        // Verify image exists
        let imageExists = await imageManager.imageExists(nameOrId: image)
        if !imageExists {
            logger.error("Image not found", metadata: ["image": "\(image)"])
            throw ContainerManagerError.imageNotFound(image)
        }

        // Generate Docker-compatible ID
        let dockerID = generateDockerID()

        // Generate container name if not provided
        let containerName = name ?? generateContainerName()

        // Use real Containerization API
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Get the image from ImageStore
        logger.debug("Retrieving image", metadata: ["image": "\(image)"])
        let containerImage = try await imageManager.getImage(nameOrId: image)

        // Get image details for metadata
        let imageDetails = try await imageManager.inspectImage(nameOrId: image)
        let imageID = imageDetails?.id ?? "sha256:" + String(repeating: "0", count: 64)

        // Create log writers for capturing stdout/stderr
        logger.debug("Creating log writers", metadata: ["docker_id": "\(dockerID)"])
        let (stdoutWriter, stderrWriter) = try logManager.createLogWriters(dockerID: dockerID)
        logWriters[dockerID] = (stdoutWriter, stderrWriter)

        // Create container using Containerization API
        logger.info("Creating container with Containerization API", metadata: [
            "docker_id": "\(dockerID)",
            "hostname": "\(containerName)"
        ])

        let linuxContainer = try await manager.create(
            dockerID,
            image: containerImage,
            rootfsSizeInBytes: 8 * 1024 * 1024 * 1024  // 8 GB
        ) { config in
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

            // Configure stdout/stderr to write to log files
            // This enables Docker-compatible log retrieval
            config.process.stdout = stdoutWriter
            config.process.stderr = stderrWriter
        }

        // Extract native ID from LinuxContainer
        let nativeID = linuxContainer.id

        // Transition container from .initialized to .created state
        // This sets up the VM, mounts rootfs, configures networking
        logger.info("Setting up container VM and runtime environment", metadata: [
            "docker_id": "\(dockerID)",
            "native_id": "\(nativeID)"
        ])
        try await linuxContainer.create()
        logger.info("Container VM created successfully", metadata: ["docker_id": "\(dockerID)"])

        // Store the native container object for later operations (start, stop, etc.)
        nativeContainers[dockerID] = linuxContainer

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
            hostConfig: HostConfig(),
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
            finishedAt: nil
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
    private func resolveContainerID(_ nameOrID: String) -> String? {
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

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

        // If container is in exited state, we need to call create() first
        // The Containerization API state machine requires: stopped -> create() -> created -> start() -> started
        if info.state == "exited" {
            logger.info("Container is exited, calling create() before start()", metadata: ["id": "\(dockerID)"])
            try await nativeContainer.create()
        }

        // Start the container using Containerization API
        logger.info("Starting container with Containerization API", metadata: ["id": "\(dockerID)"])
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

        // Spawn background monitoring task to detect when container exits
        // The task waits for the container to exit, then calls back into the actor to update state
        let monitoringTask = Task { [weak self, logger] in
            do {
                logger.debug("Background monitor: waiting for container to exit", metadata: ["id": "\(dockerID)"])
                let exitStatus = try await nativeContainer.wait(timeoutInSeconds: nil)

                logger.info("Background monitor: container exited", metadata: [
                    "id": "\(dockerID)",
                    "exit_code": "\(exitStatus.exitCode)"
                ])

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

        // Cancel monitoring task if running
        if let task = monitoringTasks.removeValue(forKey: dockerID) {
            task.cancel()
        }

        if force && info.state == "running" {
            // Stop container first if running
            logger.info("Force stopping container before removal", metadata: ["id": "\(dockerID)"])
            try? await nativeContainer.stop()
        }

        // Note: LinuxContainer doesn't have a remove() method
        // The container cleanup happens when we remove it from our tracking
        // and the LinuxContainer is deallocated
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
            return "Container not found: \(id)"
        case .containerRunning(let id):
            return "Container is running: \(id). Stop the container before removing it or use force."
        case .imageNotFound(let ref):
            return "Image not found: \(ref)"
        case .invalidConfiguration(let msg):
            return "Invalid configuration: \(msg)"
        }
    }
}

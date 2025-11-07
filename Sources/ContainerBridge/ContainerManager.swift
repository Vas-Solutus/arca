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

    // Optional VolumeManager reference for named volume resolution
    private var volumeManager: VolumeManager?

    // Optional PortMapManager reference for port publishing
    private var portMapManager: PortMapManager?

    // Shared vmnet network for NAT networking with internet access
    private var sharedNetwork: SharedVmnetNetwork?

    // State persistence
    private let stateStore: StateStore

    /// Configuration for a container whose .create() was deferred
    private struct DeferredContainerConfig {
        let image: Containerization.Image
        let entrypoint: [String]?
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
        let entrypoint: [String]?
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
        let tty: Bool
        let stdoutWriter: Writer
        let stderrWriter: Writer
        let stdinReader: ChannelReader?
        let mounts: [Containerization.Mount]
        let networkMode: String?  // "vmnet" or "bridge"/nil
        let labels: [String: String]  // Container labels for configuration
    }

    /// Handles for an attached container (stdin/stdout/stderr streams)
    public struct AttachHandles: Sendable {
        public let stdin: ChannelReader
        public let stdout: Writer
        public let stderr: Writer
        public let waitForExit: @Sendable () async throws -> Void

        public init(
            stdin: ChannelReader,
            stdout: Writer,
            stderr: Writer,
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
        logger: Logger
    ) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.stateStore = stateStore
        self.logger = logger
        self.logManager = ContainerLogManager(logger: logger)
    }

    /// Set the NetworkManager (called after NetworkManager is initialized)
    public func setNetworkManager(_ manager: NetworkManager) {
        self.networkManager = manager
    }

    /// Set the VolumeManager (called after VolumeManager is initialized)
    public func setVolumeManager(_ manager: VolumeManager) {
        self.volumeManager = manager
    }

    /// Set the PortMapManager (called after PortMapManager is initialized)
    public func setPortMapManager(_ manager: PortMapManager) {
        self.portMapManager = manager
    }

    /// Set the SharedVmnetNetwork (called after network is initialized)
    public func setSharedVmnetNetwork(_ network: SharedVmnetNetwork) {
        self.sharedNetwork = network
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

        // Initialize the native container manager with kernel, initfs, and vmnet network
        // Note: Custom vminit is loaded centrally in ArcaDaemon before any ContainerManagers are created
        // The custom vminit is tagged as "arca-vminit:latest"
        // VmnetNetwork provides NAT with internet access - used by containers with NATInterface
        // Using default subnet (let vmnet framework choose) to ensure gateway/NAT routing works
        nativeManager = try await Containerization.ContainerManager(
            kernel: kernel,
            initfsReference: "arca-vminit:latest",  // Custom vminit loaded and tagged by ArcaDaemon
            network: try Containerization.ContainerManager.VmnetNetwork()
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
                networkAttachments: networkAttachments,
                anonymousVolumes: []  // Anonymous volumes loaded from volume_mounts table
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
    /// Cancels all monitoring tasks and returns immediately
    public func shutdown() async {
        logger.info("ContainerManager graceful shutdown started")

        let taskCount = monitoringTasks.count
        logger.info("Cancelling monitoring tasks", metadata: [
            "task_count": "\(taskCount)"
        ])

        // Cancel all monitoring tasks - they will clean up asynchronously
        // We don't wait for them because they block on container.wait() indefinitely
        for (dockerID, task) in monitoringTasks {
            task.cancel()
            logger.debug("Cancelled monitoring task", metadata: [
                "container": "\(dockerID)"
            ])
        }

        // Clear the monitoring tasks dictionary
        monitoringTasks.removeAll()

        logger.info("ContainerManager graceful shutdown complete", metadata: [
            "tasks_cancelled": "\(taskCount)"
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

        // Build NetworkSettings from current network attachments
        var networks: [String: EndpointSettings] = [:]
        if let networkManager = networkManager {
            for (networkID, attachment) in info.networkAttachments {
                // Get full network metadata (includes subnet, gateway)
                if let networkMeta = await networkManager.getNetwork(id: networkID) {
                    // Parse prefix length from subnet CIDR (e.g., "172.18.0.0/16" -> 16)
                    let prefixLen: Int
                    if let slashIndex = networkMeta.subnet.firstIndex(of: "/"),
                       let prefix = Int(networkMeta.subnet[networkMeta.subnet.index(after: slashIndex)...]) {
                        prefixLen = prefix
                    } else {
                        prefixLen = 16  // Default fallback
                    }

                    networks[networkMeta.name] = EndpointSettings(
                        ipamConfig: nil,
                        links: [],
                        aliases: attachment.aliases,
                        networkID: networkID,
                        endpointID: "",
                        gateway: networkMeta.gateway,
                        ipAddress: attachment.ip,
                        ipPrefixLen: prefixLen,
                        macAddress: attachment.mac
                    )
                }
            }
        }

        // For vmnet containers, add vmnet network information
        // vmnet containers use Apple's framework-managed networking and don't have networkAttachments
        if info.hostConfig.networkMode == "vmnet", let nativeContainer = nativeContainers[dockerID] {
            // Get all vmnet interfaces from native container
            // Try to cast each interface to ContainerManager.VmnetNetwork.Interface
            var vmnetIndex = 0
            for iface in nativeContainer.interfaces {
                if let vmnetInterface = iface as? Containerization.ContainerManager.VmnetNetwork.Interface {
                    // Parse address string "192.168.81.2/24" into IP and prefix
                    let addressComponents = vmnetInterface.address.split(separator: "/")
                    let ipString = String(addressComponents[0])  // "192.168.81.2"
                    let prefixLen = addressComponents.count > 1 ? Int(addressComponents[1]) ?? 24 : 24

                    let gatewayString = vmnetInterface.gateway

                    // Use "vmnet" for the first interface, "vmnet1", "vmnet2" for additional ones
                    let networkName = vmnetIndex == 0 ? "vmnet" : "vmnet\(vmnetIndex)"

                    networks[networkName] = EndpointSettings(
                        ipamConfig: nil,
                        links: [],
                        aliases: [],
                        networkID: networkName,
                        endpointID: "",
                        gateway: gatewayString ?? "",
                        ipAddress: ipString,
                        ipPrefixLen: prefixLen,
                        macAddress: ""
                    )
                    vmnetIndex += 1
                }
            }
        }

        let networkSettings = NetworkSettings(
            bridge: "",
            sandboxID: "",
            hairpinMode: false,
            linkLocalIPv6Address: "",
            linkLocalIPv6PrefixLen: 0,
            ports: [:],
            sandboxKey: "",
            ipAddress: networks.values.first?.ipAddress ?? "",
            ipPrefixLen: networks.values.first?.ipPrefixLen ?? 0,
            gateway: networks.values.first?.gateway ?? "",
            macAddress: networks.values.first?.macAddress ?? "",
            networks: networks
        )

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
            networkSettings: networkSettings
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
        let configLogger = self.logger
        let tty = config.tty
        let stdoutWriter = config.stdoutWriter
        let stderrWriter = config.stderrWriter
        let stdinReader = config.stdinReader
        let skipEmbeddedDNS = config.labels["com.arca.skip-embedded-dns"] == "true"

        // Normalize networkMode BEFORE network lookup and capture for closure

        // Normalize networkMode: empty, "default", or "bridge" all mean the default bridge network
        // This must happen BEFORE network lookup to ensure correct network namespace configuration
        var normalizedNetworkMode: String? = config.networkMode
        if let mode = config.networkMode, (mode.isEmpty || mode == "default") {
            normalizedNetworkMode = "bridge"
            logger.debug("Normalized networkMode", metadata: [
                "docker_id": "\(dockerID)",
                "original": "\(mode)",
                "normalized": "bridge"
            ])
        }

        // Determine if network namespace is needed by checking network driver
        var tempNeedsNetworkNamespace = false
        if let networkMode = normalizedNetworkMode, networkMode != "vmnet" && networkMode != "none" {
            // Look up network to check its driver
            if let network = await networkManager?.getNetworkByName(name: networkMode) {
                tempNeedsNetworkNamespace = (network.driver == "wireguard" || network.driver == "bridge")
                logger.debug("Network driver check", metadata: [
                    "docker_id": "\(dockerID)",
                    "network": "\(networkMode)",
                    "driver": "\(network.driver)",
                    "needsNetworkNamespace": "\(tempNeedsNetworkNamespace)"
                ])
            } else {
                logger.warning("Network not found during namespace check", metadata: [
                    "docker_id": "\(dockerID)",
                    "network": "\(networkMode)"
                ])
            }
        }
        // Capture as immutable for @Sendable closure
        let needsNetworkNamespace = tempNeedsNetworkNamespace
        let effectiveNetworkMode = normalizedNetworkMode

        logger.info("Creating LinuxContainer with Containerization API", metadata: [
            "docker_id": "\(dockerID)",
            "hostname": "\(config.hostname)"
        ])

        // Get image config to properly handle entrypoint/cmd overrides
        let systemPlatform = detectSystemPlatform()
        let imagePlatform = systemPlatform.ociPlatform()
        let imageConfig = try await config.image.config(for: imagePlatform)
        let imageEntrypoint = imageConfig.config?.entrypoint ?? []
        let imageCmd = imageConfig.config?.cmd ?? []

        let container = try await manager.create(
            dockerID,
            image: config.image,
            rootfsSizeInBytes: 8 * 1024 * 1024 * 1024  // 8 GB
        ) { @Sendable containerConfig in
            // Configure the container process (OCI-compliant)
            // Implement proper Docker entrypoint/cmd semantics:
            // - effectiveEntrypoint = request.entrypoint ?? image.entrypoint
            // - effectiveCmd = request.cmd ?? image.cmd
            // - process.arguments = effectiveEntrypoint + effectiveCmd

            let effectiveEntrypoint = config.entrypoint ?? imageEntrypoint
            let effectiveCmd = config.command ?? imageCmd
            containerConfig.process.arguments = effectiveEntrypoint + effectiveCmd

            configLogger.debug("Container command", metadata: [
                "docker_id": "\(dockerID)",
                "entrypoint": "\(effectiveEntrypoint.joined(separator: " "))",
                "cmd": "\(effectiveCmd.joined(separator: " "))",
                "full_command": "\(containerConfig.process.arguments.joined(separator: " "))"
            ])

            if let env = config.env {
                // Merge with existing env from image, Docker CLI behavior
                containerConfig.process.environmentVariables += env
            }

            // Add ARCA_CONTAINER_ID for embedded-dns to query helper VM for networks
            // Skip for containers with com.arca.skip-embedded-dns label (like BuildKit)
            if !skipEmbeddedDNS {
                containerConfig.process.environmentVariables.append("ARCA_CONTAINER_ID=\(dockerID)")
                configLogger.debug("Embedded-DNS enabled for container", metadata: ["docker_id": "\(dockerID)"])
            } else {
                configLogger.debug("Embedded-DNS skipped for container (using system DNS)", metadata: ["docker_id": "\(dockerID)"])
            }

            if let workingDir = config.workingDir {
                containerConfig.process.workingDirectory = workingDir
            }

            // Set hostname (OCI spec field)
            containerConfig.hostname = config.hostname

            // Enable network namespace for WireGuard/bridge containers
            // vmnet and none containers stay in root namespace
            containerConfig.useNetworkNamespace = needsNetworkNamespace
            configLogger.debug("Network namespace configuration", metadata: [
                "docker_id": "\(dockerID)",
                "networkMode": "\(effectiveNetworkMode ?? "none")",
                "useNetworkNamespace": "\(needsNetworkNamespace)"
            ])

            // Network interface configuration:
            // The ContainerManager is initialized with VmnetNetwork (see initialize()),
            // which automatically creates eth0 for ALL containers via network?.create(id).
            // This happens BEFORE our configuration closure runs.
            //
            // For ALL network backends (vmnet, bridge/WireGuard):
            // - eth0 is created in the VM's root namespace (where vminitd lives)
            // - The network backend determines what happens next:
            //   - vmnet: eth0 is the container's only interface (direct NAT access)
            //   - bridge/WireGuard: eth0 stays in root ns, veth pairs + wgN interfaces created for container
            //
            // We do NOT override containerConfig.interfaces, allowing the framework to create eth0.
            configLogger.info("Container using framework-managed eth0 interface", metadata: [
                "container_id": "\(dockerID)",
                "networkMode": "\(effectiveNetworkMode ?? "none")"
            ])

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
        entrypoint: [String]?,
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
        binds: [String]? = nil,
        volumes: [String: Any]? = nil,  // Anonymous volumes: {"/container/path": {}}
        portBindings: [String: [PortBinding]]? = nil  // Port mappings: {"80/tcp": [PortBinding(hostIp: "0.0.0.0", hostPort: "8080")]}
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
        guard var _ = nativeManager else {
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

        // Create anonymous volumes if specified
        var anonymousVolumeNames: [String] = []
        var effectiveBinds = binds ?? []

        if let volumes = volumes, !volumes.isEmpty {
            logger.info("Creating anonymous volumes", metadata: [
                "docker_id": "\(dockerID)",
                "volume_count": "\(volumes.count)"
            ])

            guard let volumeManager = volumeManager else {
                logger.error("Anonymous volumes requested but VolumeManager not available")
                throw ContainerManagerError.volumeManagerNotAvailable
            }

            for (containerPath, _) in volumes {
                // Create anonymous volume with auto-generated name
                let volumeMetadata = try await volumeManager.createVolume(
                    name: nil,  // Auto-generate name
                    driver: "local",
                    driverOpts: nil,
                    labels: ["com.arca.anonymous": "true"]  // Mark as anonymous
                )

                anonymousVolumeNames.append(volumeMetadata.name)

                // Add to binds so it gets mounted
                effectiveBinds.append("\(volumeMetadata.name):\(containerPath)")

                logger.info("Created anonymous volume", metadata: [
                    "docker_id": "\(dockerID)",
                    "volume_name": "\(volumeMetadata.name)",
                    "container_path": "\(containerPath)"
                ])
            }
        }

        // Parse bind mounts and named volumes
        let mounts = try await parseVolumeMounts(effectiveBinds)
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
                entrypoint: entrypoint,
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
                    entrypoint: entrypoint,
                    command: command,
                    env: env,
                    workingDir: workingDir,
                    hostname: containerName,
                    tty: tty,
                    stdoutWriter: stdoutWriter,
                    stderrWriter: stderrWriter,
                    stdinReader: nil,  // Not attached
                    mounts: mounts,
                    networkMode: networkMode,
                    labels: labels ?? [:]
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
                portBindings: portBindings ?? [:],
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
            networkAttachments: [:],  // Start with no network attachments
            anonymousVolumes: anonymousVolumeNames  // Track anonymous volumes for cleanup
        )

        containers[dockerID] = containerInfo

        // Persist container state
        try await persistContainerState(dockerID: dockerID, info: containerInfo)

        // Track volume mounts in StateStore
        try await trackVolumeMounts(
            dockerID: dockerID,
            binds: effectiveBinds,
            anonymousVolumes: anonymousVolumeNames
        )

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
                    entrypoint: config.entrypoint,
                    command: config.command,
                    env: config.env,
                    workingDir: config.workingDir,
                    hostname: config.hostname,
                    tty: info.tty,
                    stdoutWriter: stdoutWriter,
                    stderrWriter: stderrWriter,
                    stdinReader: attachInfo?.handles.stdin,  // Include stdin if attached
                    mounts: config.mounts,
                    networkMode: info.hostConfig.networkMode,
                    labels: info.config.labels
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
                    try manager.delete(dockerID)
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

                // Parse volume mounts from persisted binds (includes both bind mounts and named volumes)
                let recreatedMounts = try await parseVolumeMounts(info.hostConfig.binds)

                // Resolve command and entrypoint: use persisted if provided, otherwise use image defaults
                // Empty array means "no override, use image defaults" in Docker semantics
                let resolvedCommand: [String]? = info.command.isEmpty ? nil : info.command
                let resolvedEntrypoint: [String]? = info.config.entrypoint

                // Recreate the LinuxContainer with the persisted configuration
                let container = try await createNativeContainer(
                    config: NativeContainerConfig(
                        dockerID: dockerID,
                        image: containerImage,
                        entrypoint: resolvedEntrypoint,
                        command: resolvedCommand,
                        env: info.env,
                        workingDir: info.workingDir,
                        hostname: info.config.hostname,
                        tty: info.tty,
                        stdoutWriter: stdoutLogWriter,
                        stderrWriter: stderrLogWriter,
                        stdinReader: nil,  // No stdin for recreated containers
                        mounts: recreatedMounts,
                        networkMode: info.hostConfig.networkMode,
                        labels: info.config.labels
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

        // DEBUG: Log network attachment state before attachment logic
        logger.debug("Network attachment state before attachment logic", metadata: [
            "container": "\(dockerID)",
            "networkAttachments_isEmpty": "\(info.networkAttachments.isEmpty)",
            "networkAttachments_count": "\(info.networkAttachments.count)",
            "networkAttachments_keys": "\(info.networkAttachments.keys.joined(separator: ", "))",
            "networkMode": "\(info.hostConfig.networkMode)"
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
        } else if let networkManager = networkManager,
                  !info.networkAttachments.isEmpty {
            // Container has persisted network attachments - restore them
            logger.info("🔵 NETWORK RESTORATION: Restoring persisted network attachments", metadata: [
                "container": "\(dockerID)",
                "attachmentCount": "\(info.networkAttachments.count)"
            ])

            let containerName = info.name ?? String(dockerID.prefix(12))

            for (networkID, attachment) in info.networkAttachments {
                do {
                    logger.debug("Restoring network attachment", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(networkID)",
                        "ip": "\(attachment.ip)"
                    ])

                    // Reattach to the network
                    let newAttachment = try await networkManager.attachContainerToNetwork(
                        containerID: dockerID,
                        container: nativeContainer,
                        networkID: networkID,
                        containerName: containerName,
                        aliases: attachment.aliases
                    )

                    logger.info("Network attachment restored successfully", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(networkID)",
                        "ip": "\(newAttachment.ip)"
                    ])
                } catch {
                    // Log the error but continue with other attachments
                    logger.error("Failed to restore network attachment", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(networkID)",
                        "error": "\(error)"
                    ])
                }
            }
        }

        // Push DNS topology to this container (for its own resolution)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all other containers on the same networks (to add this container)
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        // Publish ports if configured (Phase 4.1)
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty,
           let networkManager = networkManager {
            // Re-fetch updated container info after network attachment
            guard let updatedInfo = containers[dockerID] else {
                logger.warning("Container disappeared during port publishing", metadata: ["container": "\(dockerID)"])
                return
            }

            // Get WireGuard client for this container
            if let wireguardClient = await networkManager.getWireGuardClient(containerID: dockerID) {
                do {
                    // Get vmnet IP from container
                    let vmnetEndpoint = try await wireguardClient.getVmnetEndpoint()
                    let vmnetIP = vmnetEndpoint.split(separator: ":").first.map(String.init) ?? vmnetEndpoint

                    // Get overlay IP from first network attachment
                    let overlayIP = updatedInfo.networkAttachments.values.first?.ip ?? ""

                    // Publish all port mappings
                    try await portMapManager.publishPorts(
                        containerID: dockerID,
                        vmnetIP: vmnetIP,
                        overlayIP: overlayIP,
                        portBindings: info.hostConfig.portBindings,
                        wireguardClient: wireguardClient
                    )

                    logger.info("Published port mappings for container", metadata: [
                        "container": "\(dockerID)",
                        "portCount": "\(info.hostConfig.portBindings.count)"
                    ])
                } catch {
                    logger.error("Failed to publish port mappings", metadata: [
                        "container": "\(dockerID)",
                        "error": "\(error)"
                    ])
                    // Don't fail container start on port mapping errors
                }
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

        // Push DNS topology updates to remove this container from other containers' view
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        // Unpublish ports if configured (Phase 4.1)
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty,
           let networkManager = networkManager {
            // Get WireGuard client for this container
            if let wireguardClient = await networkManager.getWireGuardClient(containerID: dockerID) {
                do {
                    try await portMapManager.unpublishPorts(
                        containerID: dockerID,
                        wireguardClient: wireguardClient
                    )
                    logger.info("Unpublished port mappings for container", metadata: [
                        "container": "\(dockerID)"
                    ])
                } catch {
                    logger.warning("Failed to unpublish port mappings", metadata: [
                        "container": "\(dockerID)",
                        "error": "\(error)"
                    ])
                    // Don't fail container stop on port unpublishing errors
                }
            }
        }

        // Clean up in-memory network state (TAP devices are auto-cleaned by VM shutdown)
        if let networkManager = networkManager {
            await networkManager.cleanupStoppedContainer(containerID: dockerID)
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

    /// Pause a running container
    public func pauseContainer(id: String) async throws {
        logger.info("Pausing container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Verify container is running
        guard info.state == "running" else {
            throw ContainerManagerError.invalidConfiguration("Container is not running")
        }

        // Get native container
        guard let nativeContainer = nativeContainers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        // Pause the container via Containerization API
        try await nativeContainer.pause()

        // Update state
        info.state = "paused"
        containers[dockerID] = info

        // Persist state change
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: false)

        logger.info("Container paused successfully", metadata: ["id": "\(dockerID)"])
    }

    /// Unpause a paused container
    public func unpauseContainer(id: String) async throws {
        logger.info("Unpausing container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Verify container is paused
        guard info.state == "paused" else {
            throw ContainerManagerError.invalidConfiguration("Container is not paused")
        }

        // Get native container
        guard let nativeContainer = nativeContainers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        // Resume the container via Containerization API
        try await nativeContainer.resume()

        // Update state back to running
        info.state = "running"
        containers[dockerID] = info

        // Persist state change
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: false)

        logger.info("Container unpaused successfully", metadata: ["id": "\(dockerID)"])
    }

    /// Get container statistics
    public func getContainerStats(id: String) async throws -> Containerization.ContainerStatistics {
        logger.info("Getting container statistics", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Verify container is running
        guard info.state == "running" else {
            throw ContainerManagerError.invalidConfiguration("Container is not running")
        }

        // Get native container
        guard let nativeContainer = nativeContainers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        // Get statistics from Containerization API
        let stats = try await nativeContainer.statistics()

        logger.debug("Container statistics retrieved", metadata: [
            "id": "\(dockerID)",
            "memory_usage": "\(stats.memory.usageBytes)",
            "cpu_usage": "\(stats.cpu.usageUsec)"
        ])

        return stats
    }

    /// Rename a container
    public func renameContainer(id: String, newName: String) async throws {
        logger.info("Renaming container", metadata: [
            "id": "\(id)",
            "newName": "\(newName)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Update in-memory state
        var updatedInfo = info
        updatedInfo.name = newName
        containers[dockerID] = updatedInfo

        // Update database (will throw if name already exists due to UNIQUE constraint)
        do {
            try await stateStore.updateContainerName(id: dockerID, newName: newName)
        } catch {
            // Rollback in-memory change
            containers[dockerID] = info
            throw ContainerManagerError.invalidConfiguration("Name '\(newName)' is already in use")
        }

        logger.info("Container renamed successfully", metadata: [
            "id": "\(dockerID)",
            "oldName": "\(info.name ?? "none")",
            "newName": "\(newName)"
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

        // Unpublish ports before removal (Phase 4.1)
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty,
           let networkManager = networkManager {
            // Get WireGuard client for this container (if still available)
            if let wireguardClient = await networkManager.getWireGuardClient(containerID: dockerID) {
                do {
                    try await portMapManager.unpublishPorts(
                        containerID: dockerID,
                        wireguardClient: wireguardClient
                    )
                    logger.info("Unpublished port mappings before removal", metadata: [
                        "container": "\(dockerID)"
                    ])
                } catch {
                    logger.warning("Failed to unpublish port mappings during removal", metadata: [
                        "container": "\(dockerID)",
                        "error": "\(error)"
                    ])
                    // Don't fail container removal on port unpublishing errors
                }
            }
        }

        // Detach from all networks before removal
        // This updates the network's container list and removes IP allocations
        if let networkManager = networkManager, !info.networkAttachments.isEmpty {
            // Only detach if we have a native container object
            // For database-only containers (after daemon restart), skip detachment since
            // the container's network interfaces don't exist anyway
            if let nativeContainer = nativeContainers[dockerID] {
                logger.info("Detaching container from networks", metadata: [
                    "container": "\(dockerID)",
                    "network_count": "\(info.networkAttachments.count)"
                ])

                for networkID in info.networkAttachments.keys {
                    do {
                        // Detach from network (this removes from network's container list)
                        try await networkManager.detachContainerFromNetwork(
                            containerID: dockerID,
                            container: nativeContainer,
                            networkID: networkID
                        )
                        logger.debug("Detached container from network", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)"
                        ])
                    } catch {
                        // Log but don't fail - network might already be deleted
                        logger.warning("Failed to detach from network (may already be deleted)", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)",
                            "error": "\(error)"
                        ])
                    }
                }
            } else {
                // Database-only container - just clean up in-memory state
                logger.info("Skipping network detachment for database-only container", metadata: [
                    "container": "\(dockerID)",
                    "network_count": "\(info.networkAttachments.count)"
                ])

                // Clean up in-memory state in NetworkManager
                await networkManager.cleanupStoppedContainer(containerID: dockerID)

                // Delete network attachment records from StateStore
                for networkID in info.networkAttachments.keys {
                    do {
                        try await stateStore.deleteNetworkAttachment(
                            containerID: dockerID,
                            networkID: networkID
                        )
                        logger.debug("Deleted network attachment record", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)"
                        ])
                    } catch {
                        logger.warning("Failed to delete network attachment record", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)",
                            "error": "\(error)"
                        ])
                    }
                }
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

        // Clean up volumes before deleting container
        await cleanupVolumesForContainer(dockerID: dockerID)

        // Delete from persistent storage (CASCADE will delete volume mounts)
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

        // Clean up in-memory network state (TAP devices are auto-cleaned by VM shutdown)
        if let networkManager = networkManager {
            await networkManager.cleanupStoppedContainer(containerID: dockerID)
        }

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

    /// Get container TTY flag by ID (for attach/exec stream multiplexing)
    public func getContainerTTY(id: String) async -> Bool? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return containers[dockerID]?.tty
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

    /// Parse Docker volume mount strings into Containerization.Mount objects
    /// Supports both bind mounts and named volumes:
    /// - Bind mounts: "/host/path:/container/path[:ro]" or "relative/path:/container/path[:ro]"
    /// - Named volumes: "volume-name:/container/path[:ro]"
    private func parseVolumeMounts(_ binds: [String]?) async throws -> [Containerization.Mount] {
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

            let source = String(parts[0])
            let containerPath = String(parts[1])
            let isReadOnly = parts.count >= 3 && parts[2] == "ro"

            // Determine if this is a named volume or bind mount
            // Logic follows Docker's behavior:
            // 1. If source contains "/" or starts with "." or "~", it's a path (bind mount)
            // 2. Otherwise, check if it exists as a file/directory in current directory
            // 3. If not, treat it as a named volume
            let looksLikePath = source.contains("/") || source.hasPrefix(".") || source.hasPrefix("~")

            let expandedHostPath: String
            var isNamedVolume = false

            if looksLikePath {
                // It's a path - expand it (handles absolute, relative, and tilde paths)
                if source.hasPrefix("/") {
                    // Absolute path
                    expandedHostPath = source
                } else if source.hasPrefix("~") {
                    // Tilde path
                    expandedHostPath = NSString(string: source).expandingTildeInPath
                } else {
                    // Relative path - resolve to absolute
                    let currentDir = FileManager.default.currentDirectoryPath
                    expandedHostPath = NSString(string: currentDir).appendingPathComponent(source)
                }
            } else {
                // No path separators - could be a file in current directory or a named volume
                // Check if it exists as a file/directory in current directory
                let currentDir = FileManager.default.currentDirectoryPath
                let potentialPath = NSString(string: currentDir).appendingPathComponent(source)

                if FileManager.default.fileExists(atPath: potentialPath) {
                    // It's a file/directory in current directory - bind mount
                    expandedHostPath = potentialPath
                    logger.debug("Treating as bind mount to file in current directory", metadata: [
                        "source": "\(source)",
                        "resolvedPath": "\(expandedHostPath)"
                    ])
                } else {
                    // It doesn't exist - treat as named volume
                    guard let volumeManager = volumeManager else {
                        logger.error("Named volume requested but VolumeManager not available", metadata: [
                            "volume": "\(source)"
                        ])
                        throw ContainerManagerError.volumeManagerNotAvailable
                    }

                    do {
                        let volumeMetadata = try await volumeManager.inspectVolume(name: source)
                        expandedHostPath = volumeMetadata.mountpoint
                        isNamedVolume = true
                        logger.info("Resolved named volume", metadata: [
                            "volume": "\(source)",
                            "mountpoint": "\(expandedHostPath)",
                            "format": "\(volumeMetadata.format)"
                        ])
                    } catch {
                        logger.error("Named volume not found", metadata: [
                            "volume": "\(source)",
                            "error": "\(error)"
                        ])
                        throw ContainerManagerError.volumeNotFound(source)
                    }
                }
            }

            // Create mount options
            var options: [String] = []
            if isReadOnly {
                options.append("ro")
            }

            // Create the appropriate mount type
            let mount: Containerization.Mount
            if isNamedVolume {
                // Named volumes: Use block device mount
                // expandedHostPath is the path to volume.img file
                mount = Containerization.Mount.block(
                    format: "ext4",
                    source: expandedHostPath,
                    destination: containerPath,
                    options: options
                )
                logger.debug("Created block device mount for named volume", metadata: [
                    "source": "\(source)",
                    "blockDevice": "\(expandedHostPath)",
                    "destination": "\(containerPath)",
                    "readOnly": "\(isReadOnly)"
                ])
            } else {
                // Bind mounts: Use VirtioFS share
                // Validate host path exists (create directory if needed for rw mounts)
                let fileManager = FileManager.default
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: expandedHostPath, isDirectory: &isDirectory)

                if !exists && !isReadOnly {
                    // For read-write mounts, create the directory if it doesn't exist
                    logger.info("Creating host directory for bind mount", metadata: [
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

                mount = Containerization.Mount.share(
                    source: expandedHostPath,
                    destination: containerPath,
                    options: options
                )
                logger.debug("Created VirtioFS share for bind mount", metadata: [
                    "source": "\(source)",
                    "resolvedPath": "\(expandedHostPath)",
                    "destination": "\(containerPath)",
                    "readOnly": "\(isReadOnly)"
                ])
            }

            mounts.append(mount)
        }

        return mounts
    }

    /// Track volume mounts in StateStore for usage tracking
    private func trackVolumeMounts(
        dockerID: String,
        binds: [String],
        anonymousVolumes: [String]
    ) async throws {
        guard !binds.isEmpty else {
            return
        }

        // Parse binds to extract volume names (for named volumes)
        for bind in binds {
            let parts = bind.split(separator: ":")
            guard parts.count >= 2 else {
                continue  // Skip invalid binds
            }

            let source = String(parts[0])
            let containerPath = String(parts[1])

            // Determine if this is a named volume (vs bind mount)
            let looksLikePath = source.contains("/") || source.hasPrefix(".") || source.hasPrefix("~")

            if !looksLikePath {
                // This is a named volume - record it in StateStore
                let isAnonymous = anonymousVolumes.contains(source)

                do {
                    try await stateStore.saveVolumeMount(
                        containerID: dockerID,
                        volumeName: source,
                        containerPath: containerPath,
                        isAnonymous: isAnonymous
                    )

                    logger.debug("Tracked volume mount", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(source)",
                        "path": "\(containerPath)",
                        "anonymous": "\(isAnonymous)"
                    ])
                } catch {
                    logger.warning("Failed to track volume mount", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(source)",
                        "error": "\(error)"
                    ])
                }
            }
        }
    }

    /// Clean up volumes when a container is removed
    /// Deletes anonymous volumes and removes volume mount relationships
    private func cleanupVolumesForContainer(dockerID: String) async {
        guard let volumeManager = volumeManager else {
            return  // No volume manager, nothing to clean up
        }

        do {
            // Get all volume mounts for this container
            let mounts = try await stateStore.getVolumeMounts(containerID: dockerID)

            // Delete anonymous volumes
            for mount in mounts where mount.isAnonymous {
                logger.info("Cleaning up anonymous volume", metadata: [
                    "container": "\(dockerID)",
                    "volume": "\(mount.volumeName)"
                ])

                do {
                    try await volumeManager.deleteVolume(name: mount.volumeName, force: true)
                    logger.info("Deleted anonymous volume", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(mount.volumeName)"
                    ])
                } catch {
                    logger.warning("Failed to delete anonymous volume", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(mount.volumeName)",
                        "error": "\(error)"
                    ])
                }
            }

            // Volume mount relationships will be deleted automatically via CASCADE
            // when we delete the container from StateStore
        } catch {
            logger.warning("Failed to clean up volumes", metadata: [
                "container": "\(dockerID)",
                "error": "\(error)"
            ])
        }
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
            entrypoint: info.config.entrypoint,
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
        // TODO(Phase 3.1): Implement DNS push via WireGuard gRPC (UpdateDNSMappings RPC)
        // This will replace the tap-forwarder DNS push with a WireGuard-based implementation
        // See Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md Phase 3.1 for details

        // For now, DNS resolution is not implemented - this will be added in Phase 3.1
        // when embedded-DNS is integrated into arca-wireguard-service
        return
    }

    /// Push DNS topology updates to all containers on a specific network
    /// Called when a container joins/leaves a network or starts/stops
    private func pushDNSTopologyToNetwork(networkID: String) async {
        // TODO(Phase 3.1): Implement DNS push via WireGuard gRPC (UpdateDNSMappings RPC)
        // This will push DNS topology updates to all containers on a network
        // See Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md Phase 3.1 for details
        return
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
        var name: String?
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
        var anonymousVolumes: [String]  // Names of anonymous volumes to delete on container removal
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
    case volumeNotFound(String)
    case volumeManagerNotAvailable

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
        case .volumeNotFound(let name):
            return "No such volume: \(name)"
        case .volumeManagerNotAvailable:
            return "VolumeManager not available - named volumes are not supported"
        }
    }
}

import Foundation
import Logging
import NIOHTTP1
import DockerAPI
import ContainerBridge

/// The main Arca daemon that implements the Docker Engine API server
public final class ArcaDaemon: @unchecked Sendable {
    private let socketPath: String
    private let logger: Logger
    private var server: ArcaServer?
    private var containerManager: ContainerBridge.ContainerManager?
    private var imageManager: ImageManager?
    private var execManager: ExecManager?
    private var networkHelperVM: NetworkHelperVM?
    private var networkManager: NetworkManager?
    private var sharedNetwork: SharedVmnetNetwork?

    public init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
    }

    /// Start the daemon server
    public func start() async throws {
        logger.info("Starting Arca daemon", metadata: [
            "socket_path": "\(socketPath)",
            "api_version": "1.51"
        ])

        // Load and validate configuration
        let configManager = ConfigManager(logger: logger)
        let config = try configManager.loadConfig()

        logger.info("Configuration loaded", metadata: [
            "kernel_path": "\(config.kernelPath)",
            "socket_path": "\(config.socketPath)",
            "log_level": "\(config.logLevel)"
        ])

        // Validate that kernel exists
        try configManager.validateConfig(config)

        // Check if socket already exists (daemon might be running)
        if ArcaServer.socketExists(at: socketPath) {
            logger.warning("Socket file already exists", metadata: [
                "socket_path": "\(socketPath)"
            ])
            // Try to remove it, if we can't, the daemon might be running
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                throw DaemonError.socketAlreadyExists(socketPath)
            }
        }

        // Initialize ImageManager
        let imageManager = try ImageManager(logger: logger, imageStorePath: nil)
        self.imageManager = imageManager

        do {
            try await imageManager.initialize()
        } catch {
            logger.warning("ImageManager initialization incomplete", metadata: [
                "error": "\(error)"
            ])
            // Continue anyway - we can still serve API requests
        }

        // Load custom vminit image BEFORE creating any ContainerManagers
        // This ensures both helper VM and main ContainerManager use the same vminit
        let vminitPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca")
            .appendingPathComponent("vminit")

        var initfsReference = "vminit:latest"  // Default reference

        if FileManager.default.fileExists(atPath: vminitPath.path) {
            logger.info("Loading custom vminit image from OCI layout", metadata: [
                "path": "\(vminitPath.path)"
            ])

            // Delete the existing initfs.ext4 file to force regeneration from our custom vminit
            // Without this, the old initfs.ext4 (which may be from a different vminit) gets reused
            let initfsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.containerization/initfs.ext4")
            if FileManager.default.fileExists(atPath: initfsPath.path) {
                logger.debug("Deleting existing initfs.ext4 to force regeneration")
                do {
                    try FileManager.default.removeItem(at: initfsPath)
                    logger.debug("Deleted old initfs.ext4 successfully")
                } catch {
                    logger.warning("Failed to delete old initfs.ext4", metadata: [
                        "error": "\(error)"
                    ])
                }
            }

            // Delete existing arca-vminit image to force reload
            if await imageManager.imageExists(nameOrId: "arca-vminit:latest") {
                logger.debug("Deleting existing arca-vminit:latest to reload fresh version")
                _ = try? await imageManager.deleteImage(nameOrId: "arca-vminit:latest", force: true)
            }

            // Load the OCI layout into ImageStore
            // The OCI layout already has the image tagged as "arca-vminit:latest" via the index annotation
            do {
                let loadedImages = try await imageManager.loadFromOCILayout(directory: vminitPath)
                logger.info("Custom vminit image loaded successfully", metadata: [
                    "count": "\(loadedImages.count)",
                    "images": "\(loadedImages.map { $0.reference }.joined(separator: ", "))"
                ])

                // Verify the image was loaded with the correct reference
                if let firstImage = loadedImages.first {
                    if firstImage.reference == "arca-vminit:latest" {
                        initfsReference = "arca-vminit:latest"
                        logger.info("Custom vminit ready to use: \(initfsReference)")
                    } else {
                        logger.warning("Loaded vminit has unexpected reference: \(firstImage.reference)")
                    }
                }
            } catch {
                logger.warning("Failed to load custom vminit, will use default", metadata: [
                    "error": "\(error)"
                ])
            }
        } else {
            logger.warning("Custom vminit not found at \(vminitPath.path), will use default vminit")
        }

        // Initialize networking components based on configured backend
        var networkHelperVM: NetworkHelperVM? = nil

        switch config.networkBackend {
        case .ovs:
            // OVS backend requires helper VM
            logger.info("Initializing OVS backend with network helper VM...")
            let helperVM = NetworkHelperVM(
                imageManager: imageManager,
                kernelPath: config.kernelPath,
                logger: logger,
                sharedNetwork: nil  // OVS doesn't use shared vmnet
            )
            self.networkHelperVM = helperVM
            networkHelperVM = helperVM

            do {
                try await helperVM.initialize()
                try await helperVM.start()
                logger.info("Network helper VM started successfully")
            } catch {
                logger.error("Failed to start network helper VM", metadata: [
                    "error": "\(error)"
                ])
                logger.warning("Daemon will continue without network helper VM - OVS networking disabled")
                networkHelperVM = nil
            }

        case .vmnet:
            // vmnet backend doesn't need helper VM
            logger.info("Using vmnet backend - no helper VM required")
            self.networkHelperVM = nil
        }

        // Initialize StateStore (shared by ContainerManager and NetworkManager)
        let stateDBPath = NSString(string: "~/.arca/state.db").expandingTildeInPath
        let stateStore: StateStore
        do {
            stateStore = try StateStore(path: stateDBPath, logger: logger)
            logger.info("StateStore initialized", metadata: ["path": "\(stateDBPath)"])
        } catch {
            logger.error("Failed to initialize StateStore", metadata: ["error": "\(error)"])
            throw error
        }

        // Initialize ContainerManager with kernel path from config
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            stateStore: stateStore,
            logger: logger,
            sharedNetwork: nil  // No longer using shared vmnet for networking
        )
        self.containerManager = containerManager

        do {
            try await containerManager.initialize()
        } catch {
            logger.error("ContainerManager initialization failed", metadata: [
                "error": "\(error)"
            ])
            throw error
        }

        // Initialize ExecManager
        let execManager = ExecManager(containerManager: containerManager, logger: logger)
        self.execManager = execManager

        // Initialize NetworkBridge for TAP device management and packet relay
        let networkBridge: NetworkBridge?
        if config.networkBackend == .ovs, let helperVM = networkHelperVM {
            let bridge = NetworkBridge(logger: logger)
            await bridge.setHelperVM(helperVM)
            networkBridge = bridge
        } else {
            networkBridge = nil
        }

        // Initialize NetworkManager with selected backend
        logger.info("Initializing network manager with \(config.networkBackend.rawValue) backend...")
        let nm = NetworkManager(
            config: config,
            stateStore: stateStore,
            helperVM: networkHelperVM,
            networkBridge: networkBridge,
            logger: logger
        )
        self.networkManager = nm
        var networkManager: NetworkManager? = nm

        do {
            try await nm.initialize()
            logger.info("Network manager initialized successfully")

            // Wire up NetworkManager reference in ContainerManager for auto-attachment
            await containerManager.setNetworkManager(nm)
            logger.debug("ContainerManager configured with NetworkManager")
        } catch {
            logger.error("Failed to initialize network manager", metadata: [
                "error": "\(error)"
            ])
            // Continue without network manager - networking features won't be available
            logger.warning("Daemon will continue without network manager - networking features disabled")
            self.networkManager = nil
            networkManager = nil
        }

        // Create router builder, register middlewares and routes
        let builder = Router.builder(logger: logger)
            .use(RequestLogger(logger: logger))
            .use(APIVersionNormalizer())
        registerRoutes(
            builder: builder,
            containerManager: containerManager,
            imageManager: imageManager,
            execManager: execManager,
            networkManager: networkManager
        )
        let router = builder.build()

        // Create and start server
        let server = ArcaServer(socketPath: socketPath, router: router, execManager: execManager, containerManager: containerManager, logger: logger)
        self.server = server

        try await server.start()
    }

    /// Stop the daemon server
    public func shutdown() async throws {
        logger.info("Stopping Arca daemon")

        guard let server = server else {
            logger.warning("Server not running")
            return
        }

        // Gracefully shutdown ContainerManager (wait for monitoring tasks)
        if let containerManager = containerManager {
            logger.info("Gracefully shutting down ContainerManager...")
            await containerManager.shutdown()
        }

        try await server.shutdown()
        self.server = nil

        // Stop network helper VM if running
        if let networkHelperVM = networkHelperVM {
            logger.info("Stopping network helper VM...")
            do {
                try await networkHelperVM.stop()
                logger.info("Network helper VM stopped")
            } catch {
                logger.error("Error stopping network helper VM", metadata: [
                    "error": "\(error)"
                ])
            }
            self.networkHelperVM = nil
        }

        logger.info("Arca daemon stopped")
    }

    /// Register all API routes
    private func registerRoutes(
        builder: RouterBuilder,
        containerManager: ContainerBridge.ContainerManager,
        imageManager: ImageManager,
        execManager: ExecManager,
        networkManager: NetworkManager?
    ) {
        logger.info("Registering API routes")

        // Create handlers
        let containerHandlers = ContainerHandlers(containerManager: containerManager, imageManager: imageManager, logger: logger)
        let imageHandlers = ImageHandlers(imageManager: imageManager, logger: logger)
        let execHandlers = ExecHandlers(execManager: execManager, logger: logger)
        let networkHandlers = networkManager.map { NetworkHandlers(networkManager: $0, containerManager: containerManager, logger: logger) }

        // System endpoints - Ping (GET and HEAD)
        _ = builder.get("/_ping") { _ in
            let response = SystemHandlers.handlePing()
            let body = Data("OK".utf8)
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(body.count)")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: body))
        }

        _ = builder.head("/_ping") { _ in
            let response = SystemHandlers.handlePing()
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Length", value: "0")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: nil))
        }

        _ = builder.get("/version") { _ in
            let response = SystemHandlers.handleVersion()
            return .standard(HTTPResponse.json(response))
        }

        // Container endpoints - List
        _ = builder.get("/containers/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let limit = try QueryParameterValidator.parsePositiveInt(request.queryParameters["limit"], paramName: "limit")
                let size = QueryParameterValidator.parseBoolean(request.queryParameters["size"])
                let filters = try QueryParameterValidator.parseDockerFiltersToSingle(request.queryParameters["filters"])

                // Call handler asynchronously
                let listResponse = await containerHandlers.handleListContainers(
                    all: all,
                    limit: limit,
                    size: size,
                    filters: filters
                )

                if let error = listResponse.error {
                    return .standard(HTTPResponse.internalServerError(
                        "Failed to list containers: \(error.localizedDescription)"
                    ))
                }

                return .standard(HTTPResponse.ok(listResponse.containers))
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid query parameters: \(error.localizedDescription)"))
            }
        }

        // Container endpoints - Create
        _ = builder.post("/containers/create") { request in
            // Parse container name from query parameters
            let name = request.queryString("name")

            // Parse JSON body
            do {
                let createRequest = try request.jsonBody(ContainerCreateRequest.self)

                // Call handler
                let result = await containerHandlers.handleCreateContainer(request: createRequest, name: name)

                switch result {
                case .success(let response):
                    return .standard(HTTPResponse.created(response))
                case .failure(let error):
                    // Return 404 for image not found so Docker CLI knows to pull
                    if case .imageNotFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
            }
        }

        // Container endpoints - Start
        _ = builder.post("/containers/{id}/start") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleStartContainer(id: id)

            switch result {
            case .success:
                return .standard(HTTPResponse.noContent())
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Stop
        _ = builder.post("/containers/{id}/stop") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Validate timeout parameter
            do {
                let timeout = try QueryParameterValidator.parseNonNegativeInt(request.queryParameters["t"], paramName: "t")

                let result = await containerHandlers.handleStopContainer(id: id, timeout: timeout)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    // Map ContainerError to appropriate HTTP status
                    switch error {
                    case .notFound:
                        return .standard(HTTPResponse.notFound(error.description))
                    default:
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.badRequest("Invalid query parameters: \(error.localizedDescription)"))
            }
        }

        // Container endpoints - Remove
        _ = builder.delete("/containers/{id}") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let force = request.queryParameters["force"] == "true" || request.queryParameters["force"] == "1"
            let volumes = request.queryParameters["v"] == "true" || request.queryParameters["v"] == "1"

            let result = await containerHandlers.handleRemoveContainer(id: id, force: force, removeVolumes: volumes)

            switch result {
            case .success:
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                return .standard(HTTPResponse(status: .noContent, headers: headers))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Inspect
        _ = builder.get("/containers/{id}/json") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let result = await containerHandlers.handleInspectContainer(id: id)

            switch result {
            case .success(let inspect):
                return .standard(HTTPResponse.json(inspect))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Container endpoints - Logs
        _ = builder.get("/containers/{id}/logs") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Validate query parameters
            do {
                let stdout = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stdout"])
                let stderr = QueryParameterValidator.parseBooleanDefaultTrue(request.queryParameters["stderr"])
                let follow = QueryParameterValidator.parseBoolean(request.queryParameters["follow"])
                let timestamps = QueryParameterValidator.parseBoolean(request.queryParameters["timestamps"])
                let since = try QueryParameterValidator.parseUnixTimestamp(request.queryParameters["since"], paramName: "since")
                let until = try QueryParameterValidator.parseUnixTimestamp(request.queryParameters["until"], paramName: "until")
                let tail = try QueryParameterValidator.parseTail(request.queryParameters["tail"])

                // Use streaming handler which supports both streaming and standard responses
                return await containerHandlers.handleLogsContainerStreaming(
                    idOrName: id,
                    stdout: stdout,
                    stderr: stderr,
                    follow: follow,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    tail: tail
                )
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        _ = builder.post("/containers/{id}/attach") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let stdout = request.queryParameters["stdout"] == "1"
            let stderr = request.queryParameters["stderr"] == "1"
            let stream = request.queryParameters["stream"] == "1"

            return await containerHandlers.handleLogsContainerStreaming(
                idOrName: id,
                stdout: stdout,
                stderr: stderr,
                follow: stream,
                since: nil as Int?,
                until: nil as Int?,
                timestamps: false,
                tail: nil as String?
            )
        }

        _ = builder.post("/containers/{id}/wait") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Wait for container to exit and return exit code
            let result = await containerHandlers.handleWaitContainer(idOrName: id)

            switch result {
            case .success(let exitCode):
                let response = ["StatusCode": exitCode]
                return .standard(HTTPResponse.json(response))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.post("/containers/{id}/resize") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            let height = request.queryParameters["h"].flatMap { Int($0) }
            let width = request.queryParameters["w"].flatMap { Int($0) }

            let result = await containerHandlers.handleResizeContainer(id: id, height: height, width: width)

            switch result {
            case .success:
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                return .standard(HTTPResponse(status: .ok, headers: headers))
            case .failure(let error):
                return .standard(HTTPResponse.error(error.description, status: .internalServerError))
            }
        }

        // Exec endpoints
        _ = builder.post("/containers/{id}/exec") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing container ID"))
            }

            // Parse JSON body
            guard let body = request.body,
                  let execConfig = try? JSONDecoder().decode(ExecConfig.self, from: body) else {
                return .standard(HTTPResponse.error("Invalid or missing request body", status: .badRequest))
            }

            let result = await execHandlers.handleCreateExec(containerID: id, config: execConfig)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response, status: .created))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not running") ? .conflict : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        _ = builder.post("/exec/{id}/start") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            // Parse JSON body
            guard let body = request.body,
                  let startConfig = try? JSONDecoder().decode(ExecStartConfig.self, from: body) else {
                return .standard(HTTPResponse.error("Invalid or missing request body", status: .badRequest))
            }

            // Handler returns HTTPResponseType directly (streaming or standard)
            return await execHandlers.handleStartExec(execID: id, config: startConfig)
        }

        // Exec endpoints - Resize
        _ = builder.post("/exec/{id}/resize") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            let height = request.queryParameters["h"].flatMap(Int.init)
            let width = request.queryParameters["w"].flatMap(Int.init)

            return await execHandlers.handleResizeExec(execID: id, height: height, width: width)
        }

        // Exec endpoints - Inspect
        _ = builder.get("/exec/{id}/json") { request in
            guard let id = request.pathParam("id") else {
                return .standard(HTTPResponse.badRequest("Missing exec ID"))
            }

            let result = await execHandlers.handleInspectExec(execID: id)

            switch result {
            case .success(let inspect):
                return .standard(HTTPResponse.json(inspect))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Image endpoints
        _ = builder.get("/images/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let digests = QueryParameterValidator.parseBoolean(request.queryParameters["digests"])
                let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                // Call handler asynchronously
                let listResponse = await imageHandlers.handleListImages(
                    all: all,
                    filters: filters,
                    digests: digests
                )

                if let error = listResponse.error {
                    return .standard(HTTPResponse.error(
                        "Failed to list images: \(error.localizedDescription)",
                        status: .internalServerError
                    ))
                }

                return .standard(HTTPResponse.json(listResponse.images))
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        _ = builder.post("/images/create") { request in
            // Parse query parameters
            guard let fromImage = request.queryParameters["fromImage"] else {
                return .standard(HTTPResponse.error("Missing 'fromImage' query parameter", status: .badRequest))
            }

            let tag = request.queryParameters["tag"]
            let platform = request.queryParameters["platform"]

            // Parse authentication from X-Registry-Auth header
            var auth: RegistryAuthentication?
            if let authHeader = request.headers.first(name: "X-Registry-Auth") {
                if let authConfig = try? RegistryAuthConfig.fromBase64(authHeader) {
                    auth = RegistryAuthentication(
                        username: authConfig.username,
                        password: authConfig.password,
                        email: authConfig.email,
                        serverAddress: authConfig.serveraddress,
                        identityToken: authConfig.identitytoken,
                        registryToken: authConfig.registrytoken
                    )
                }
            }

            // Call streaming handler for real-time progress updates
            return await imageHandlers.handlePullImageStreaming(
                fromImage: fromImage,
                tag: tag,
                platform: platform,
                auth: auth
            )
        }

        _ = builder.delete("/images/{name}") { request in
            guard let name = request.pathParam("name") else {
                return .standard(HTTPResponse.badRequest("Missing image name"))
            }

            let force = request.queryParameters["force"] == "true" || request.queryParameters["force"] == "1"
            let noprune = request.queryParameters["noprune"] == "true" || request.queryParameters["noprune"] == "1"

            let result = await imageHandlers.handleDeleteImage(nameOrId: name, force: force, noprune: noprune)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response))
            case .failure(let error):
                // Return 404 for image not found, 500 for other errors
                let status: HTTPResponseStatus = {
                    if case .imageNotFound = error {
                        return .notFound
                    }
                    return .internalServerError
                }()
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        // Network endpoints
        if let networkHandlers = networkHandlers {
            _ = builder.get("/networks") { request in
                do {
                    let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

                    let result = await networkHandlers.handleListNetworks(filters: filters)

                    switch result {
                    case .success(let networks):
                        return .standard(HTTPResponse.ok(networks))
                    case .failure(let error):
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
                }
            }

            _ = builder.get("/networks/{id}") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                let result = await networkHandlers.handleInspectNetwork(id: id)

                switch result {
                case .success(let network):
                    return .standard(HTTPResponse.ok(network))
                case .failure(let error):
                    if case .notFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }

            _ = builder.post("/networks/create") { request in
                do {
                    let createRequest = try request.jsonBody(NetworkCreateRequest.self)

                    let result = await networkHandlers.handleCreateNetwork(request: createRequest)

                    switch result {
                    case .success(let response):
                        return .standard(HTTPResponse.created(response))
                    case .failure(let error):
                        if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        } else if case .invalidRequest = error {
                            return .standard(HTTPResponse.badRequest(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            _ = builder.delete("/networks/{id}") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                let force = request.queryBool("force")

                let result = await networkHandlers.handleDeleteNetwork(id: id, force: force)

                switch result {
                case .success:
                    return .standard(HTTPResponse.noContent())
                case .failure(let error):
                    if case .notFound = error {
                        return .standard(HTTPResponse.notFound(error.description))
                    } else if case .conflict = error {
                        return .standard(HTTPResponse.conflict(error.description))
                    }
                    return .standard(HTTPResponse.internalServerError(error.description))
                }
            }

            _ = builder.post("/networks/{id}/connect") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                do {
                    let connectRequest = try request.jsonBody(NetworkConnectRequest.self)

                    // Resolve container name/ID to full Docker ID
                    guard let dockerID = await containerManager.resolveContainerID(connectRequest.container) else {
                        return .standard(HTTPResponse.notFound("container", id: connectRequest.container))
                    }

                    // Get container name
                    let containerName = await containerManager.getContainerName(dockerID: dockerID) ?? dockerID

                    let result = await networkHandlers.handleConnectNetwork(
                        networkID: id,
                        containerID: dockerID,
                        containerName: containerName,
                        endpointConfig: connectRequest.endpointConfig
                    )

                    switch result {
                    case .success:
                        return .standard(HTTPResponse.json([String: String](), status: .ok))  // Docker returns empty object
                    case .failure(let error):
                        if case .notFound = error {
                            return .standard(HTTPResponse.notFound(error.description))
                        } else if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            _ = builder.post("/networks/{id}/disconnect") { request in
                guard let id = request.pathParam("id") else {
                    return .standard(HTTPResponse.badRequest("Missing network ID"))
                }

                do {
                    let disconnectRequest = try request.jsonBody(NetworkDisconnectRequest.self)

                    // Resolve container name/ID to full Docker ID
                    guard let dockerID = await containerManager.resolveContainerID(disconnectRequest.container) else {
                        return .standard(HTTPResponse.notFound("container", id: disconnectRequest.container))
                    }

                    let result = await networkHandlers.handleDisconnectNetwork(
                        networkID: id,
                        containerID: dockerID,
                        force: disconnectRequest.force ?? false
                    )

                    switch result {
                    case .success:
                        return .standard(HTTPResponse.json([String: String](), status: .ok))  // Docker returns empty object
                    case .failure(let error):
                        if case .notFound = error {
                            return .standard(HTTPResponse.notFound(error.description))
                        } else if case .conflict = error {
                            return .standard(HTTPResponse.conflict(error.description))
                        }
                        return .standard(HTTPResponse.internalServerError(error.description))
                    }
                } catch {
                    return .standard(HTTPResponse.badRequest("Invalid or missing request body"))
                }
            }

            logger.info("Registered 23 routes (including 6 network routes)")
        } else {
            logger.info("Registered 17 routes (network routes skipped - NetworkManager not available)")
        }
    }

    /// Check if the daemon is running
    public static func isRunning(socketPath: String) -> Bool {
        return ArcaServer.socketExists(at: socketPath)
    }
}

// MARK: - Error Types

public enum DaemonError: Error, CustomStringConvertible {
    case socketAlreadyExists(String)

    public var description: String {
        switch self {
        case .socketAlreadyExists(let path):
            return "Socket already exists at \(path). Is the daemon already running?"
        }
    }
}

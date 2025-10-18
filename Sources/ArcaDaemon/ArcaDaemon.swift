import Foundation
import Logging
import NIOHTTP1
import DockerAPI
import ContainerBridge

/// The main Arca daemon that implements the Docker Engine API server
public final class ArcaDaemon {
    private let socketPath: String
    private let logger: Logger
    private var server: ArcaServer?
    private var containerManager: ContainerManager?
    private var imageManager: ImageManager?

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

        // Initialize ContainerManager with kernel path from config
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: config.kernelPath,
            logger: logger
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

        // Create router and register routes
        let router = Router(logger: logger)
        registerRoutes(router: router, containerManager: containerManager, imageManager: imageManager)

        // Create and start server
        let server = ArcaServer(socketPath: socketPath, router: router, logger: logger)
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

        try await server.shutdown()
        self.server = nil

        logger.info("Arca daemon stopped")
    }

    /// Register all API routes
    private func registerRoutes(router: Router, containerManager: ContainerManager, imageManager: ImageManager) {
        logger.info("Registering API routes")

        // Create handlers
        let containerHandlers = ContainerHandlers(containerManager: containerManager, logger: logger)
        let imageHandlers = ImageHandlers(imageManager: imageManager, logger: logger)

        // System endpoints - Ping (GET and HEAD)
        router.register(method: .GET, pattern: "/_ping") { _ in
            let response = SystemHandlers.handlePing()
            let body = Data("OK".utf8)
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(body.count)")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: body))
        }

        router.register(method: .HEAD, pattern: "/_ping") { _ in
            let response = SystemHandlers.handlePing()
            var headers = HTTPHeaders()
            headers.add(name: "API-Version", value: response.apiVersion)
            headers.add(name: "OSType", value: response.osType)
            headers.add(name: "Content-Length", value: "0")
            return .standard(HTTPResponse(status: .ok, headers: headers, body: nil))
        }

        router.register(method: .GET, pattern: "/version") { _ in
            let response = SystemHandlers.handleVersion()
            return .standard(HTTPResponse.json(response))
        }

        // Container endpoints - List
        router.register(method: .GET, pattern: "/containers/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let limit = try QueryParameterValidator.parsePositiveInt(request.queryParameters["limit"], paramName: "limit")
                let size = QueryParameterValidator.parseBoolean(request.queryParameters["size"])

                // Parse filters JSON from query parameter
                let filters: [String: String] = try QueryParameterValidator.parseFilters(request.queryParameters["filters"]) ?? [:]

                // Call handler asynchronously
                let listResponse = await containerHandlers.handleListContainers(
                    all: all,
                    limit: limit,
                    size: size,
                    filters: filters
                )

                if let error = listResponse.error {
                    return .standard(HTTPResponse.error(
                        "Failed to list containers: \(error.localizedDescription)",
                        status: .internalServerError
                    ))
                }

                return .standard(HTTPResponse.json(listResponse.containers))
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        // Container endpoints - Create
        router.register(method: .POST, pattern: "/containers/create") { request in
            // Parse container name from query parameters
            let name = request.queryParameters["name"]

            // Parse JSON body
            guard let body = request.body,
                  let createRequest = try? JSONDecoder().decode(ContainerCreateRequest.self, from: body) else {
                return .standard(HTTPResponse.error("Invalid or missing request body", status: .badRequest))
            }

            // Call handler
            let result = await containerHandlers.handleCreateContainer(request: createRequest, name: name)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response, status: .created))
            case .failure(let error):
                return .standard(HTTPResponse.error(error.description, status: .internalServerError))
            }
        }

        // Container endpoints - Start
        router.register(method: .POST, pattern: "/containers/{id}/start") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
            }

            let result = await containerHandlers.handleStartContainer(id: id)

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

        // Container endpoints - Stop
        router.register(method: .POST, pattern: "/containers/{id}/stop") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
            }

            // Validate timeout parameter
            do {
                let timeout = try QueryParameterValidator.parseNonNegativeInt(request.queryParameters["t"], paramName: "t")

                let result = await containerHandlers.handleStopContainer(id: id, timeout: timeout)

                switch result {
                case .success:
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Length", value: "0")
                    return .standard(HTTPResponse(status: .noContent, headers: headers))
                case .failure(let error):
                    let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                    return .standard(HTTPResponse.error(error.description, status: status))
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        // Container endpoints - Remove
        router.register(method: .DELETE, pattern: "/containers/{id}") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
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
        router.register(method: .GET, pattern: "/containers/{id}/json") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
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
        router.register(method: .GET, pattern: "/containers/{id}/logs") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
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

                let result = await containerHandlers.handleLogsContainer(
                    idOrName: id,
                    stdout: stdout,
                    stderr: stderr,
                    follow: follow,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    tail: tail
                )

                switch result {
                case .success(let logsData):
                    // Return binary multiplexed stream data
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "application/vnd.docker.raw-stream")
                    headers.add(name: "Content-Length", value: "\(logsData.count)")
                    return .standard(HTTPResponse(status: .ok, headers: headers, body: logsData))
                case .failure(let error):
                    let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                    return .standard(HTTPResponse.error(error.description, status: status))
                }
            } catch let error as ValidationError {
                return .standard(error.toHTTPResponse())
            } catch {
                return .standard(HTTPResponse.error("Invalid query parameters: \(error.localizedDescription)", status: .badRequest))
            }
        }

        router.register(method: .POST, pattern: "/containers/{id}/attach") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
            }

            // Parse attach parameters (similar to logs endpoint)
            let stdout = request.queryParameters["stdout"] == "1"
            let stderr = request.queryParameters["stderr"] == "1"
            let stream = request.queryParameters["stream"] == "1"

            // For now, use the logs handler to return container output
            // Full attach implementation would require HTTP hijacking for bidirectional streaming
            let result = await containerHandlers.handleLogsContainer(
                idOrName: id,
                stdout: stdout,
                stderr: stderr,
                follow: stream,  // Use stream param for follow
                since: nil,
                until: nil,
                timestamps: false,
                tail: nil
            )

            switch result {
            case .success(let logsData):
                // Return binary multiplexed stream for attach
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/vnd.docker.raw-stream")
                headers.add(name: "Content-Length", value: "\(logsData.count)")
                return .standard(HTTPResponse(status: .ok, headers: headers, body: logsData))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        router.register(method: .POST, pattern: "/containers/{id}/wait") { request in
            guard let id = request.pathParameters["id"] else {
                return .standard(HTTPResponse.error("Missing container ID", status: .badRequest))
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

        // Image endpoints
        router.register(method: .GET, pattern: "/images/json") { request in
            // Validate and parse query parameters
            do {
                let all = QueryParameterValidator.parseBoolean(request.queryParameters["all"])
                let digests = QueryParameterValidator.parseBoolean(request.queryParameters["digests"])

                // Parse filters JSON from query parameter
                let filters: [String: [String]] = try QueryParameterValidator.parseFilters(request.queryParameters["filters"]) ?? [:]

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

        router.register(method: .POST, pattern: "/images/create") { request in
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

        router.register(method: .DELETE, pattern: "/images/{name}") { request in
            guard let name = request.pathParameters["name"] else {
                return .standard(HTTPResponse.error("Missing image name", status: .badRequest))
            }

            let force = request.queryParameters["force"] == "true" || request.queryParameters["force"] == "1"
            let noprune = request.queryParameters["noprune"] == "true" || request.queryParameters["noprune"] == "1"

            let result = await imageHandlers.handleDeleteImage(nameOrId: name, force: force, noprune: noprune)

            switch result {
            case .success(let response):
                return .standard(HTTPResponse.json(response))
            case .failure(let error):
                let status: HTTPResponseStatus = error.description.contains("not found") ? .notFound : .internalServerError
                return .standard(HTTPResponse.error(error.description, status: status))
            }
        }

        logger.info("Registered 14 routes")
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

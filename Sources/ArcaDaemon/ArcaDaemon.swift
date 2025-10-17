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
        let imageManager = ImageManager(logger: logger)
        self.imageManager = imageManager

        do {
            try await imageManager.initialize()
        } catch {
            logger.warning("ImageManager initialization incomplete", metadata: [
                "error": "\(error)"
            ])
            // Continue anyway - we can still serve API requests
        }

        // Initialize ContainerManager
        let containerManager = ContainerManager(imageManager: imageManager, logger: logger)
        self.containerManager = containerManager

        do {
            try await containerManager.initialize()
        } catch {
            logger.warning("ContainerManager initialization incomplete", metadata: [
                "error": "\(error)"
            ])
            // Continue anyway - we can still serve API requests
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

        // System endpoints
        router.register(method: .GET, pattern: "/_ping") { _ in
            let response = SystemHandlers.handlePing()
            return HTTPResponse.json(response)
        }

        router.register(method: .GET, pattern: "/version") { _ in
            let response = SystemHandlers.handleVersion()
            return HTTPResponse.json(response)
        }

        // Container endpoints
        router.register(method: .GET, pattern: "/containers/json") { request in
            // Parse query parameters
            let all = request.queryParameters["all"] == "true" || request.queryParameters["all"] == "1"
            let limit = request.queryParameters["limit"].flatMap { Int($0) }
            let size = request.queryParameters["size"] == "true" || request.queryParameters["size"] == "1"

            // TODO: Parse filters JSON from query parameter
            let filters: [String: String] = [:]

            // Call handler asynchronously
            let listResponse = await containerHandlers.handleListContainers(
                all: all,
                limit: limit,
                size: size,
                filters: filters
            )

            if let error = listResponse.error {
                return HTTPResponse.error(
                    "Failed to list containers: \(error.localizedDescription)",
                    status: .internalServerError
                )
            }

            return HTTPResponse.json(listResponse.containers)
        }

        // Image endpoints
        router.register(method: .GET, pattern: "/images/json") { request in
            // Parse query parameters
            let all = request.queryParameters["all"] == "true" || request.queryParameters["all"] == "1"
            let digests = request.queryParameters["digests"] == "true" || request.queryParameters["digests"] == "1"

            // TODO: Parse filters JSON from query parameter
            let filters: [String: [String]] = [:]

            // Call handler asynchronously
            let listResponse = await imageHandlers.handleListImages(
                all: all,
                filters: filters,
                digests: digests
            )

            if let error = listResponse.error {
                return HTTPResponse.error(
                    "Failed to list images: \(error.localizedDescription)",
                    status: .internalServerError
                )
            }

            return HTTPResponse.json(listResponse.images)
        }

        router.register(method: .POST, pattern: "/images/create") { request in
            // Parse query parameters
            guard let fromImage = request.queryParameters["fromImage"] else {
                return HTTPResponse.error("Missing 'fromImage' query parameter", status: .badRequest)
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

            // Call handler asynchronously
            let result = await imageHandlers.handlePullImage(
                fromImage: fromImage,
                tag: tag,
                platform: platform,
                auth: auth
            )

            switch result {
            case .success(let response):
                return HTTPResponse.json(response)
            case .failure(let error):
                return HTTPResponse.error(error.description, status: .internalServerError)
            }
        }

        logger.info("Registered 5 routes")
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

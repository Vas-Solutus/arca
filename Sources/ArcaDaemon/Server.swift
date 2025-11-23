import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOPosix
import ContainerBridge

/// The Arca HTTP server that listens on a Unix socket
/// @unchecked Sendable: Safe because:
/// - Immutable properties (socketPath, router, execManager, containerManager, logger) are set during init and never modified
/// - Mutable properties (group, channel) are only accessed from server lifecycle methods (start/shutdown)
/// - NIO guarantees channel initializer closures are properly isolated to their event loops
public final class ArcaServer: @unchecked Sendable {
    private let socketPath: String
    private let router: Router
    private let execManager: ExecManager
    private let containerManager: ContainerManager
    private let logManager: ContainerBridge.ContainerLogManager
    private let logger: Logger

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init(socketPath: String, router: Router, execManager: ExecManager, containerManager: ContainerManager, logger: Logger) {
        self.socketPath = socketPath
        self.router = router
        self.execManager = execManager
        self.containerManager = containerManager
        self.logManager = containerManager.logManager
        self.logger = logger
    }

    /// Start the server
    public func start() async throws {
        logger.info("Starting Arca server", metadata: [
            "socket_path": "\(socketPath)",
            "api_version": "1.51"
        ])

        // Clean up existing socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create event loop group
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = eventLoopGroup

        // Create bootstrap for Unix domain socket server
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Create Docker raw stream upgrader for exec/attach operations
                let dockerUpgrader = DockerRawStreamUpgrader(execManager: self.execManager, containerManager: self.containerManager, logManager: self.logManager, logger: self.logger)

                // Configure HTTP pipeline with upgrade support
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [dockerUpgrader],
                        completionHandler: { context in
                            // Upgrade completed successfully
                            self.logger.debug("HTTP upgrade completed for connection")
                        }
                    )
                ).flatMap {
                    // Add our HTTP handler for normal (non-upgraded) requests
                    channel.pipeline.addHandler(HTTPHandler(router: self.router, logger: self.logger))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        do {
            // Bind to Unix domain socket
            let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
            self.channel = channel

            logger.info("Arca server started successfully", metadata: [
                "socket_path": "\(socketPath)"
            ])

            // Set socket permissions to allow connections
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o666],
                ofItemAtPath: socketPath
            )

            logger.info("Server listening for connections")

            // Wait for the server to close
            try await channel.closeFuture.get()
        } catch {
            logger.error("Failed to start server", metadata: [
                "error": "\(error)"
            ])
            try? await shutdown()
            throw error
        }
    }

    /// Stop the server gracefully
    public func shutdown() async throws {
        logger.info("Shutting down Arca server")

        // Close the channel
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }

        // Shutdown event loop group
        if let group = group {
            try? await group.shutdownGracefully()
            self.group = nil
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        logger.info("Arca server stopped")
    }

    /// Check if a socket file exists and has an active process listening
    /// Automatically removes stale socket files (no process bound)
    public static func socketExists(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        // Check if socket is actually bound to a process by attempting to connect
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let clientBootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }

        do {
            let channel = try clientBootstrap.connect(unixDomainSocketPath: path).wait()
            try channel.close().wait()
            // Connection succeeded - socket is active
            return true
        } catch {
            // Connection failed - socket is stale, remove it
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
    }
}

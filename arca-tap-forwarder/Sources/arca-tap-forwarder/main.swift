// Arca TAP Forwarder Daemon
// gRPC server for managing TAP network devices in container VMs
// Part of the Arca project - Docker Engine API on Apple's Containerization framework

import Foundation
import Logging
import GRPC
import NIOCore
import NIOPosix

#if os(Linux)

let CONTROL_PLANE_PORT: UInt32 = 5555
let VERSION = "1.0.0"

// Setup logging
LoggingSystem.bootstrap(StreamLogHandler.standardError)
var logger = Logger(label: "arca-tap-forwarder")
logger.logLevel = .debug

logger.info("Arca TAP Forwarder Daemon starting...", metadata: [
    "version": "\(VERSION)",
    "controlPort": "\(CONTROL_PLANE_PORT)"
])

// Create event loop group
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

Task {
    do {
        // Create gRPC service
        let service = TAPForwarderService(logger: logger)

        // Configure vsock server - bind to all interfaces on vsock
        // grpc-swift doesn't have direct vsock support, use TCP localhost for now
        // vminit will handle vsock forwarding
        let server = try await Server.insecure(group: group)
            .withServiceProviders([service])
            .withLogger(logger)
            .bind(host: "127.0.0.1", port: Int(CONTROL_PLANE_PORT))
            .get()

        logger.info("gRPC server listening", metadata: [
            "host": "127.0.0.1",
            "port": "\(CONTROL_PLANE_PORT)"
        ])

        // Wait for server to complete (runs until signal)
        try await server.onClose.get()

        logger.info("TAP Forwarder Daemon shutting down...")

        // Shutdown event loop
        try await group.shutdownGracefully()
    } catch {
        logger.error("Fatal error", metadata: ["error": "\(error)"])
        exit(1)
    }
}

// Keep main thread alive
RunLoop.current.run()

#else

print("arca-tap-forwarder only runs on Linux")
exit(1)

#endif

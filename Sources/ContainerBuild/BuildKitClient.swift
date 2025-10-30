import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// BuildKitClient handles gRPC communication with BuildKit container via vsock
///
/// Provides high-level wrappers around BuildKit's Control API:
/// - Solve() - Execute build operations
/// - Status() - Stream build progress
/// - ListWorkers() - Health checks and worker info
public actor BuildKitClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Moby_Buildkit_V1_ControlNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum BuildKitClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case operationFailed(String)
        case invalidRequest(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "BuildKit client not connected"
            case .connectionFailed(let reason):
                return "Failed to connect to BuildKit: \(reason)"
            case .operationFailed(let reason):
                return "BuildKit operation failed: \(reason)"
            case .invalidRequest(let reason):
                return "Invalid BuildKit request: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.build.buildkitclient")
    }

    /// Connect to BuildKit container via vsock using LinuxContainer.dialVsock()
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 8088) async throws {
        logger.info("Connecting to BuildKit via vsock (LinuxContainer.dialVsock())", metadata: [
            "vsockPort": "\(vsockPort)"
        ])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        // Use LinuxContainer.dialVsock() to get a FileHandle for the vsock connection
        logger.debug("Calling container.dialVsock(\(vsockPort))...")
        let fileHandle = try await container.dialVsock(port: vsockPort)
        logger.debug("container.dialVsock() successful, got file handle", metadata: [
            "fd": "\(fileHandle.fileDescriptor)"
        ])

        // Store FileHandle to keep it alive for the lifetime of the connection
        self.vsockFileHandle = fileHandle

        // Create gRPC channel from the connected socket FileHandle
        let channel = ClientConnection(
            configuration: .default(
                target: .connectedSocket(NIOBSDSocket.Handle(fileHandle.fileDescriptor)),
                eventLoopGroup: group
            ))

        self.channel = channel
        self.client = Moby_Buildkit_V1_ControlNIOClient(channel: channel)

        logger.info("Connected to BuildKit control API via vsock")
    }

    /// Disconnect from BuildKit
    public func disconnect() async {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from BuildKit")

        // Close gRPC channel
        do {
            try await channel.close().get()
        } catch {
            logger.warning("Error closing gRPC channel", metadata: ["error": "\(error)"])
        }

        // Shutdown event loop group
        do {
            try await eventLoopGroup?.shutdownGracefully()
        } catch {
            logger.warning("Error shutting down event loop", metadata: ["error": "\(error)"])
        }

        // Close the vsock FileHandle
        if let fileHandle = vsockFileHandle {
            try? fileHandle.close()
        }

        self.channel = nil
        self.eventLoopGroup = nil
        self.client = nil
        self.vsockFileHandle = nil

        logger.info("Disconnected from BuildKit")
    }

    // MARK: - BuildKit Control API Methods

    /// Execute a build (Solve RPC)
    ///
    /// - Parameters:
    ///   - definition: LLB build graph definition
    ///   - frontend: Frontend to use (e.g., "dockerfile.v0")
    ///   - frontendAttrs: Frontend-specific attributes
    /// - Returns: Solve response with exported image references
    public func solve(
        definition: Pb_Definition?,
        frontend: String?,
        frontendAttrs: [String: String]
    ) async throws -> Moby_Buildkit_V1_SolveResponse {
        guard let client = client else {
            throw BuildKitClientError.notConnected
        }

        logger.info("Executing build (Solve RPC)", metadata: [
            "frontend": "\(frontend ?? "none")",
            "hasDefinition": "\(definition != nil)"
        ])

        var request = Moby_Buildkit_V1_SolveRequest()

        if let definition = definition {
            request.definition = definition
        }

        if let frontend = frontend {
            request.frontend = frontend
        }

        request.frontendAttrs = frontendAttrs

        let call = client.solve(request)

        do {
            let response = try await call.response.get()
            logger.info("Build completed successfully")
            return response
        } catch {
            logger.error("Build failed", metadata: ["error": "\(error)"])
            throw BuildKitClientError.operationFailed("\(error)")
        }
    }

    /// Stream build progress (Status RPC)
    ///
    /// - Parameter ref: Build reference (typically from Solve request)
    /// - Parameter handler: Callback for each status update
    public func streamStatus(
        ref: String,
        handler: @escaping (Moby_Buildkit_V1_StatusResponse) -> Void
    ) async throws {
        guard let client = client else {
            throw BuildKitClientError.notConnected
        }

        logger.info("Streaming build status", metadata: ["ref": "\(ref)"])

        var request = Moby_Buildkit_V1_StatusRequest()
        request.ref = ref

        let call = client.status(request) { response in
            handler(response)
        }

        do {
            _ = try await call.status.get()
            logger.debug("Status stream completed")
        } catch {
            logger.warning("Status stream error", metadata: ["error": "\(error)"])
            throw BuildKitClientError.operationFailed("\(error)")
        }
    }

    /// List BuildKit workers (for health checks)
    ///
    /// - Returns: Array of worker information
    public func listWorkers() async throws -> [Moby_Buildkit_V1_Types_WorkerRecord] {
        guard let client = client else {
            throw BuildKitClientError.notConnected
        }

        logger.debug("Listing BuildKit workers")

        let request = Moby_Buildkit_V1_ListWorkersRequest()
        let call = client.listWorkers(request)

        do {
            let response = try await call.response.get()
            logger.debug("Retrieved \(response.record.count) workers")
            return response.record
        } catch {
            logger.warning("Failed to list workers", metadata: ["error": "\(error)"])
            throw BuildKitClientError.operationFailed("\(error)")
        }
    }

    /// Prune BuildKit cache
    ///
    /// - Parameter keepDuration: Keep cache entries accessed within this duration
    /// - Parameter keepStorage: Target storage size to keep (bytes)
    /// - Returns: Disk usage response
    public func prune(keepDuration: Int64? = nil, keepStorage: Int64? = nil) async throws -> Moby_Buildkit_V1_DiskUsageResponse {
        guard let client = client else {
            throw BuildKitClientError.notConnected
        }

        logger.info("Pruning BuildKit cache")

        var request = Moby_Buildkit_V1_PruneRequest()
        if let keepDuration = keepDuration {
            request.keepDuration = keepDuration
        }
        if let keepStorage = keepStorage {
            request.maxUsedSpace = keepStorage
        }

        // Prune returns a stream of usage records
        var response = Moby_Buildkit_V1_DiskUsageResponse()
        let call = client.prune(request) { record in
            // Collect records in response
            response.record.append(record)
        }

        do {
            _ = try await call.status.get()
            logger.info("Cache pruned successfully")
            return response
        } catch {
            logger.error("Failed to prune cache", metadata: ["error": "\(error)"])
            throw BuildKitClientError.operationFailed("\(error)")
        }
    }

    /// Get disk usage information
    ///
    /// - Returns: Disk usage response with cache statistics
    public func diskUsage() async throws -> Moby_Buildkit_V1_DiskUsageResponse {
        guard let client = client else {
            throw BuildKitClientError.notConnected
        }

        logger.debug("Getting BuildKit disk usage")

        let request = Moby_Buildkit_V1_DiskUsageRequest()
        let call = client.diskUsage(request)

        do {
            let response = try await call.response.get()
            logger.debug("Retrieved disk usage info: \(response.record.count) records")
            return response
        } catch {
            logger.warning("Failed to get disk usage", metadata: ["error": "\(error)"])
            throw BuildKitClientError.operationFailed("\(error)")
        }
    }
}

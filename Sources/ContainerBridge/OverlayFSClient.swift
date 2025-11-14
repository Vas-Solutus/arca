import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// OverlayFSClient handles gRPC communication with the container's OverlayFS service via vsock
public actor OverlayFSClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Overlayfs_V1_OverlayFSServiceNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum OverlayFSClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case mountFailed(String)
        case unmountFailed(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "OverlayFS client not connected to container"
            case .connectionFailed(let reason):
                return "Failed to connect to container: \(reason)"
            case .mountFailed(let reason):
                return "OverlayFS mount failed: \(reason)"
            case .unmountFailed(let reason):
                return "OverlayFS unmount failed: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.overlayfs.client")
    }

    /// Connect to a container's OverlayFS service via vsock using LinuxContainer.dialVsock()
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 51821) async throws {
        logger.info("Connecting to container OverlayFS service via vsock", metadata: [
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
        self.client = Arca_Overlayfs_V1_OverlayFSServiceNIOClient(channel: channel)

        logger.info("Connected to container OverlayFS service via vsock")
    }

    /// Disconnect from the container's OverlayFS service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from container OverlayFS service")

        try await channel.close().get()
        try await eventLoopGroup?.shutdownGracefully()

        // Close the vsock FileHandle
        if let fileHandle = vsockFileHandle {
            try? fileHandle.close()
        }

        self.channel = nil
        self.eventLoopGroup = nil
        self.client = nil
        self.vsockFileHandle = nil

        logger.info("Disconnected from container OverlayFS service")
    }

    /// Mount OverlayFS with multiple lower layers
    ///
    /// - Parameters:
    ///   - lowerBlockDevices: Block device paths in guest (e.g., ["/dev/vda", "/dev/vdb", "/dev/vdc"])
    ///   - upperDir: Path to upper (writable) directory in guest
    ///   - workDir: Path to work directory in guest
    ///   - target: Mount point (typically "/")
    /// - Throws: OverlayFSClientError if mount fails
    public func mountOverlay(
        lowerBlockDevices: [String],
        upperDir: String,
        workDir: String,
        target: String
    ) async throws {
        guard let client = client else {
            throw OverlayFSClientError.notConnected
        }

        logger.info("Mounting OverlayFS", metadata: [
            "layers": "\(lowerBlockDevices.count)",
            "upperDir": "\(upperDir)",
            "workDir": "\(workDir)",
            "target": "\(target)"
        ])

        let request = Arca_Overlayfs_V1_MountOverlayRequest.with {
            $0.lowerBlockDevices = lowerBlockDevices
            $0.upperDir = upperDir
            $0.workDir = workDir
            $0.target = target
        }

        do {
            let response = try await client.mountOverlay(request).response.get()

            guard response.success else {
                let errorMessage = response.errorMessage.isEmpty ? "Unknown error" : response.errorMessage
                logger.error("OverlayFS mount failed", metadata: [
                    "error": "\(errorMessage)"
                ])
                throw OverlayFSClientError.mountFailed(errorMessage)
            }

            logger.info("OverlayFS mounted successfully", metadata: [
                "layers": "\(lowerBlockDevices.count)",
                "target": "\(target)"
            ])
        } catch let error as OverlayFSClientError {
            throw error
        } catch {
            logger.error("OverlayFS mount RPC failed", metadata: [
                "error": "\(error)"
            ])
            throw OverlayFSClientError.mountFailed(error.localizedDescription)
        }
    }

    /// Unmount OverlayFS
    ///
    /// - Parameter target: Mount point to unmount (typically "/")
    /// - Throws: OverlayFSClientError if unmount fails
    public func unmountOverlay(target: String) async throws {
        guard let client = client else {
            throw OverlayFSClientError.notConnected
        }

        logger.info("Unmounting OverlayFS", metadata: [
            "target": "\(target)"
        ])

        let request = Arca_Overlayfs_V1_UnmountOverlayRequest.with {
            $0.target = target
        }

        do {
            let response = try await client.unmountOverlay(request).response.get()

            guard response.success else {
                let errorMessage = response.errorMessage.isEmpty ? "Unknown error" : response.errorMessage
                logger.error("OverlayFS unmount failed", metadata: [
                    "error": "\(errorMessage)"
                ])
                throw OverlayFSClientError.unmountFailed(errorMessage)
            }

            logger.info("OverlayFS unmounted successfully", metadata: [
                "target": "\(target)"
            ])
        } catch let error as OverlayFSClientError {
            throw error
        } catch {
            logger.error("OverlayFS unmount RPC failed", metadata: [
                "error": "\(error)"
            ])
            throw OverlayFSClientError.unmountFailed(error.localizedDescription)
        }
    }
}
// FilesystemClient.swift
// Swift client for Arca Filesystem Service gRPC API
//
// Provides filesystem operations for containers:
// - Filesystem sync (flush buffers)
// - OverlayFS upperdir enumeration (for docker diff)
// - Archive operations (tar creation/extraction for buildx)

import Foundation
import GRPC
import NIO
import NIOPosix
import Logging
import Containerization

/// Client for communicating with arca-filesystem-service running in container VM
/// Connects via vsock port 51821
public actor FilesystemClient {
    private let logger: Logger
    private let containerID: String
    private let container: Containerization.LinuxContainer
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Filesystem_V1_FilesystemServiceAsyncClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public init(containerID: String, container: Containerization.LinuxContainer, logger: Logger) {
        self.containerID = containerID
        self.container = container
        self.logger = logger
    }

    /// Connect to the container's filesystem service via vsock
    private func connect() async throws {
        guard client == nil else { return }

        logger.debug("Connecting to container filesystem service via vsock", metadata: [
            "container": "\(containerID)",
            "vsockPort": "51821"
        ])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        // Use LinuxContainer.dialVsock() to get a FileHandle for the vsock connection
        let fileHandle = try await container.dialVsock(port: 51821)
        logger.debug("container.dialVsock(51821) successful", metadata: [
            "container": "\(containerID)",
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
        self.client = Arca_Filesystem_V1_FilesystemServiceAsyncClient(channel: channel)

        logger.debug("Connected to container filesystem service via vsock", metadata: [
            "container": "\(containerID)"
        ])
    }

    /// Get or create gRPC client connection
    private func getClient() async throws -> Arca_Filesystem_V1_FilesystemServiceAsyncClient {
        if let existing = client {
            return existing
        }

        try await connect()

        guard let client = client else {
            throw FilesystemClientError.connectionFailed("Failed to create client after connect()")
        }

        return client
    }

    /// Disconnect from the container's filesystem service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.debug("Disconnecting from container filesystem service", metadata: [
            "container": "\(containerID)"
        ])

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

        logger.debug("Disconnected from container filesystem service", metadata: [
            "container": "\(containerID)"
        ])
    }

    /// Sync filesystem - flush all cached writes to disk
    /// Calls sync() syscall to ensure accurate filesystem reads
    public func syncFilesystem() async throws {
        logger.debug("Syncing filesystem", metadata: ["container": "\(containerID)"])

        let client = try await getClient()
        let request = Arca_Filesystem_V1_SyncFilesystemRequest()

        let response = try await client.syncFilesystem(request)

        guard response.success else {
            logger.error("Filesystem sync failed", metadata: [
                "container": "\(containerID)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.syncFailed(response.error)
        }

        logger.debug("Filesystem sync complete", metadata: ["container": "\(containerID)"])
    }

    /// Enumerate OverlayFS upperdir for container diff
    /// Returns all files in /mnt/vdb/upper (added/modified files and whiteouts)
    /// Much faster than full filesystem enumeration
    public func enumerateUpperdir() async throws -> [UpperdirEntry] {
        logger.debug("Enumerating upperdir", metadata: ["container": "\(containerID)"])

        let client = try await getClient()
        let request = Arca_Filesystem_V1_EnumerateUpperdirRequest()

        let response = try await client.enumerateUpperdir(request)

        guard response.success else {
            logger.error("Upperdir enumeration failed", metadata: [
                "container": "\(containerID)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.enumerationFailed(response.error)
        }

        logger.debug("Upperdir enumeration complete", metadata: [
            "container": "\(containerID)",
            "entries": "\(response.entries.count)"
        ])

        return response.entries.map { entry in
            UpperdirEntry(
                path: entry.path,
                type: entry.type,
                size: entry.size,
                mtime: entry.mtime,
                mode: entry.mode
            )
        }
    }

    /// Read archive - create tar archive of filesystem path
    /// Works universally without requiring tar in container
    /// Used for GET /containers/{id}/archive endpoint (buildx)
    public func readArchive(path: String) async throws -> (tarData: Data, stat: PathStat) {
        logger.debug("Reading archive", metadata: [
            "container": "\(containerID)",
            "path": "\(path)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_ReadArchiveRequest()
        request.containerID = containerID
        request.path = path

        let response = try await client.readArchive(request)

        guard response.success else {
            logger.error("Read archive failed", metadata: [
                "container": "\(containerID)",
                "path": "\(path)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.readArchiveFailed(response.error)
        }

        let stat = PathStat(
            name: response.stat.name,
            size: response.stat.size,
            mode: response.stat.mode,
            mtime: response.stat.mtime,
            linkTarget: response.stat.linkTarget
        )

        logger.debug("Read archive complete", metadata: [
            "container": "\(containerID)",
            "path": "\(path)",
            "size": "\(response.tarData.count)"
        ])

        return (tarData: response.tarData, stat: stat)
    }

    /// Write archive - extract tar archive to filesystem path
    /// Works universally without requiring tar in container
    /// Used for PUT /containers/{id}/archive endpoint (buildx)
    public func writeArchive(path: String, tarData: Data) async throws {
        logger.debug("Writing archive", metadata: [
            "container": "\(containerID)",
            "path": "\(path)",
            "size": "\(tarData.count)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_WriteArchiveRequest()
        request.containerID = containerID
        request.path = path
        request.tarData = tarData

        let response = try await client.writeArchive(request)

        guard response.success else {
            logger.error("Write archive failed", metadata: [
                "container": "\(containerID)",
                "path": "\(path)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.writeArchiveFailed(response.error)
        }

        logger.debug("Write archive complete", metadata: [
            "container": "\(containerID)",
            "path": "\(path)"
        ])
    }
}

/// Entry in the OverlayFS upperdir (for docker diff)
public struct UpperdirEntry: Sendable {
    public let path: String
    public let type: String  // "file", "dir", "symlink", "whiteout"
    public let size: Int64
    public let mtime: Int64
    public let mode: UInt32

    public init(path: String, type: String, size: Int64, mtime: Int64, mode: UInt32) {
        self.path = path
        self.type = type
        self.size = size
        self.mtime = mtime
        self.mode = mode
    }
}

/// File stat information for archived paths
public struct PathStat: Sendable {
    public let name: String
    public let size: Int64
    public let mode: UInt32
    public let mtime: String  // RFC3339 format
    public let linkTarget: String

    public init(name: String, size: Int64, mode: UInt32, mtime: String, linkTarget: String) {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
        self.linkTarget = linkTarget
    }
}

/// Errors from FilesystemClient
public enum FilesystemClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case syncFailed(String)
    case enumerationFailed(String)
    case readArchiveFailed(String)
    case writeArchiveFailed(String)

    public var description: String {
        switch self {
        case .connectionFailed(let msg):
            return "Failed to connect to filesystem service: \(msg)"
        case .syncFailed(let msg):
            return "Filesystem sync failed: \(msg)"
        case .enumerationFailed(let msg):
            return "Upperdir enumeration failed: \(msg)"
        case .readArchiveFailed(let msg):
            return "Read archive failed: \(msg)"
        case .writeArchiveFailed(let msg):
            return "Write archive failed: \(msg)"
        }
    }
}

// ProcessControlClient.swift
// Swift client for Arca Process Control Service gRPC API
//
// Provides process control operations for containers:
// - List processes (reads /proc directly without spawning /bin/ps)
// - Process status checking
//
// Connects via vsock port 51822

import Foundation
import GRPC
import NIO
import NIOPosix
import Logging
import Containerization

/// Client for communicating with arca-process-service running in container VM
/// Connects via vsock port 51822
public actor ProcessControlClient {
    private let logger: Logger
    private let containerID: String
    private let container: Containerization.LinuxContainer
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Process_V1_ProcessServiceAsyncClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public init(containerID: String, container: Containerization.LinuxContainer, logger: Logger) {
        self.containerID = containerID
        self.container = container
        self.logger = logger
    }

    /// Connect to the container's process control service via vsock
    private func connect() async throws {
        guard client == nil else { return }

        logger.debug("Connecting to container process control service via vsock", metadata: [
            "container": "\(containerID)",
            "vsockPort": "51822"
        ])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        // Use LinuxContainer.dialVsock() to get a FileHandle for the vsock connection
        let fileHandle = try await container.dialVsock(port: 51822)
        logger.debug("container.dialVsock(51822) successful", metadata: [
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
        self.client = Arca_Process_V1_ProcessServiceAsyncClient(channel: channel)

        logger.debug("Connected to container process control service via vsock", metadata: [
            "container": "\(containerID)"
        ])
    }

    /// Get or create gRPC client connection
    private func getClient() async throws -> Arca_Process_V1_ProcessServiceAsyncClient {
        if let existing = client {
            return existing
        }

        try await connect()

        guard let client = client else {
            throw ProcessControlClientError.connectionFailed("Failed to create client after connect()")
        }

        return client
    }

    /// Disconnect from the container's process control service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.debug("Disconnecting from container process control service", metadata: [
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

        logger.debug("Disconnected from container process control service", metadata: [
            "container": "\(containerID)"
        ])
    }

    /// List all processes running in the container
    /// Reads /proc filesystem directly without spawning /bin/ps (no race condition)
    /// Returns process information in ps -ef format
    public func listProcesses(psArgs: String? = nil) async throws -> ProcessListResponse {
        logger.debug("Listing processes", metadata: [
            "container": "\(containerID)",
            "psArgs": "\(psArgs ?? "-ef")"
        ])

        let client = try await getClient()
        var request = Arca_Process_V1_ListProcessesRequest()
        request.psArgs = psArgs ?? ""

        let response = try await client.listProcesses(request)

        logger.debug("List processes complete", metadata: [
            "container": "\(containerID)",
            "processCount": "\(response.processes.count)"
        ])

        return ProcessListResponse(
            titles: response.titles,
            processes: response.processes.map { $0.values }
        )
    }
}

/// Process list response in ps -ef format
public struct ProcessListResponse: Sendable {
    public let titles: [String]        // Column headers (e.g., ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
    public let processes: [[String]]   // Each process as array of values corresponding to titles

    public init(titles: [String], processes: [[String]]) {
        self.titles = titles
        self.processes = processes
    }
}

/// Errors from ProcessControlClient
public enum ProcessControlClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case listProcessesFailed(String)

    public var description: String {
        switch self {
        case .connectionFailed(let msg):
            return "Failed to connect to process control service: \(msg)"
        case .listProcessesFailed(let msg):
            return "List processes failed: \(msg)"
        }
    }
}

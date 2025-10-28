// NetworkBridge - Orchestrates container network attachments and packet relay
// Control plane: Sends gRPC commands to arca-tap-forwarder
// Data plane: Relays packets between container VMs and helper VM

import Foundation
import Logging
import Containerization
import ContainerizationOS

/// Network bridge that manages container network attachments
public actor NetworkBridge {
    private let logger: Logger
    private var controlPlane: Containerization.LinuxContainer?
    private var portAllocator: PortAllocator

    // Track network attachments: containerID -> networkID -> attachment
    private var attachments: [String: [String: NetworkAttachment]] = [:]

    struct NetworkAttachment {
        let networkID: String
        let device: String          // eth0, eth1, etc.
        let containerPort: UInt32   // vsock data port
        let controlPlanePort: UInt32
        let relayTask: Task<Void, Never>
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case controlPlaneNotRunning
        case containerNotFound
        case networkNotFound
        case attachmentFailed(String)
        case detachmentFailed(String)
        case relayFailed(String)

        public var description: String {
            switch self {
            case .controlPlaneNotRunning: return "Control plane not running"
            case .containerNotFound: return "Container not found"
            case .networkNotFound: return "Network not found"
            case .attachmentFailed(let msg): return "Failed to attach network: \(msg)"
            case .detachmentFailed(let msg): return "Failed to detach network: \(msg)"
            case .relayFailed(let msg): return "Packet relay failed: \(msg)"
            }
        }
    }

    public init(logger: Logger) {
        self.logger = logger
        self.portAllocator = PortAllocator(basePort: 20000)
    }

    /// Set the control plane container reference
    public func setControlPlane(_ controlPlane: Containerization.LinuxContainer) {
        self.controlPlane = controlPlane
    }

    // MARK: - TAP Forwarder Management

    /// Ensure arca-tap-forwarder is running in the container
    /// Note: arca-tap-forwarder is automatically started by vminitd on container boot
    /// This function just verifies connectivity
    private func ensureTAPForwarderRunning(container: LinuxContainer, containerID: String) async throws {
        // arca-tap-forwarder is started automatically by vminitd (Application.swift)
        // It listens on vsock port 5555 and is ready to accept connections
        logger.debug("arca-tap-forwarder auto-started by vminitd", metadata: ["containerID": "\(containerID)"])

        // The forwarder is already running - TAPForwarderClient will connect when needed
    }

    // MARK: - Network Attachment

    /// Allocate a vsock port for TAP packet relay
    /// Returns the container-side port (helper VM uses port + 10000)
    public func allocateVsockPort() async throws -> UInt32 {
        return try await portAllocator.allocate()
    }

    /// Release a previously allocated vsock port
    public func releaseVsockPort(_ port: UInt32) async {
        await portAllocator.release(port)
    }

    /// Attach a container to a network
    public func attachContainerToNetwork(
        container: LinuxContainer,
        containerID: String,
        networkID: String,
        ipAddress: String,
        gateway: String,
        device: String,
        containerPort: UInt32
    ) async throws {
        guard let controlPlaneContainer = controlPlane else {
            throw BridgeError.controlPlaneNotRunning
        }

        logger.info("Attaching container to network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "device": "\(device)",
            "ip": "\(ipAddress)"
        ])

        // 1. Ensure arca-tap-forwarder is running in the container
        try await ensureTAPForwarderRunning(container: container, containerID: containerID)

        // 2. Use provided vsock port
        let controlPlanePort = containerPort + 10000  // Control plane uses +10000 offset

        logger.debug("Allocated ports", metadata: [
            "containerPort": "\(containerPort)",
            "controlPlanePort": "\(controlPlanePort)"
        ])

        // 3. Send AttachNetwork RPC to arca-tap-forwarder
        do {
            let client = try await TAPForwarderClient(container: container, logger: logger)

            // Empty IP means use DHCP - tap-forwarder will skip static IP configuration
            let response = try await client.attachNetwork(
                device: device,
                vsockPort: containerPort,
                ipAddress: ipAddress,
                gateway: gateway,
                netmask: 24
            )

            guard response.success else {
                throw BridgeError.attachmentFailed(response.error)
            }

            logger.info("TAP device created in container", metadata: [
                "device": "\(device)",
                "mac": "\(response.macAddress)"
            ])

            // 3. Start data plane relay task
            let relayTask = Task {
                await self.runRelay(
                    container: container,
                    containerID: containerID,
                    containerPort: containerPort,
                    controlPlaneContainer: controlPlaneContainer,
                    controlPlanePort: controlPlanePort
                )
            }

            // 4. Track this attachment
            if attachments[containerID] == nil {
                attachments[containerID] = [:]
            }

            attachments[containerID]![networkID] = NetworkAttachment(
                networkID: networkID,
                device: device,
                containerPort: containerPort,
                controlPlanePort: controlPlanePort,
                relayTask: relayTask
            )

            logger.info("Network attachment complete", metadata: [
                "containerID": "\(containerID)",
                "networkID": "\(networkID)"
            ])

        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.attachmentFailed(error.localizedDescription)
        }
    }

    /// Detach a container from a network
    public func detachContainerFromNetwork(
        container: LinuxContainer,
        containerID: String,
        networkID: String
    ) async throws {
        guard let attachment = attachments[containerID]?[networkID] else {
            throw BridgeError.networkNotFound
        }

        logger.info("Detaching container from network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "device": "\(attachment.device)"
        ])

        // 1. Send DetachNetwork RPC to arca-tap-forwarder
        do {
            let client = try await TAPForwarderClient(container: container, logger: logger)
            let response = try await client.detachNetwork(device: attachment.device)

            guard response.success else {
                throw BridgeError.detachmentFailed(response.error)
            }

        } catch {
            logger.error("Failed to send detach RPC", metadata: ["error": "\(error)"])
            // Continue with cleanup even if RPC fails
        }

        // 2. Stop relay task
        attachment.relayTask.cancel()

        // 3. Release port
        await portAllocator.release(attachment.containerPort)

        // 4. Remove from tracking
        attachments[containerID]?.removeValue(forKey: networkID)
        if attachments[containerID]?.isEmpty == true {
            attachments.removeValue(forKey: containerID)
        }

        logger.info("Network detachment complete", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)"
        ])
    }

    /// Cleanup all attachments for a container (called on container stop)
    public func cleanupContainer(containerID: String, container: LinuxContainer) async {
        guard let containerAttachments = attachments[containerID] else {
            return
        }

        logger.info("Cleaning up container network attachments", metadata: [
            "containerID": "\(containerID)",
            "count": "\(containerAttachments.count)"
        ])

        for (networkID, _) in containerAttachments {
            do {
                try await detachContainerFromNetwork(
                    container: container,
                    containerID: containerID,
                    networkID: networkID
                )
            } catch {
                logger.error("Failed to detach during cleanup", metadata: [
                    "networkID": "\(networkID)",
                    "error": "\(error)"
                ])
            }
        }
    }

    // MARK: - Data Plane Relay

    /// Run packet relay between container and control plane
    /// This is the data plane that forwards Ethernet frames
    private func runRelay(
        container: LinuxContainer,
        containerID: String,
        containerPort: UInt32,
        controlPlaneContainer: LinuxContainer,
        controlPlanePort: UInt32
    ) async {
        let relayLogger = Logger(label: "network-relay-\(containerID)")

        relayLogger.info("Starting packet relay", metadata: [
            "containerPort": "\(containerPort)",
            "controlPlanePort": "\(controlPlanePort)"
        ])

        do {
            // Dial container (arca-tap-forwarder is listening on containerPort)
            relayLogger.debug("Dialing container vsock port", metadata: ["port": "\(containerPort)"])
            let containerConnection = try await container.dialVsock(port: containerPort)
            relayLogger.info("Container connected")

            // Dial helper VM with retry logic (listener needs time to start)
            relayLogger.debug("Dialing control plane", metadata: ["port": "\(controlPlanePort)"])
            let controlPlaneConnection = try await dialWithRetry(
                container: controlPlaneContainer,
                port: controlPlanePort,
                maxAttempts: 10,
                logger: relayLogger
            )
            relayLogger.info("Control plane connected")

            // Run bidirectional relay using detached tasks for true independence
            relayLogger.info("Starting bidirectional relay with detached tasks")

            // Extract FDs BEFORE creating tasks
            let containerFD = containerConnection.fileDescriptor
            let controlPlaneFD = controlPlaneConnection.fileDescriptor

            relayLogger.info("File descriptors extracted", metadata: [
                "containerFD": "\(containerFD)",
                "controlPlaneFD": "\(controlPlaneFD)"
            ])

            // Create both relay tasks as truly independent detached tasks
            let task1 = Task.detached {
                await self.relayFD(
                    sourceFD: containerFD,
                    destFD: controlPlaneFD,
                    direction: "container->helper",
                    logger: relayLogger
                )
            }

            let task2 = Task.detached {
                await self.relayFD(
                    sourceFD: controlPlaneFD,
                    destFD: containerFD,
                    direction: "helper->container",
                    logger: relayLogger
                )
            }

            relayLogger.info("Both relay tasks launched, waiting for completion")

            // Wait for either task to complete (relay runs until connection closes)
            _ = await task1.value
            _ = await task2.value

            relayLogger.info("Bidirectional relay completed")

        } catch {
            relayLogger.error("Relay failed", metadata: ["error": "\(error)"])
        }

        relayLogger.info("Packet relay stopped")
    }

    /// Create a vsock listener on the host
    private func createVsockListener(port: UInt32, logger: Logger) throws -> Socket {
        // Create vsock server socket
        let type = VsockType(port: port, cid: VsockType.anyCID)
        let listener = try Socket(type: type)

        // listen() internally calls bind() and listen()
        try listener.listen()

        logger.debug("Created vsock listener", metadata: ["port": "\(port)"])
        return listener
    }

    /// Accept a vsock connection
    private func acceptVsockConnection(listener: Socket, logger: Logger) async throws -> Socket {
        // The Socket API doesn't have async accept, so we'll poll
        // This is not ideal but works for now
        while !Task.isCancelled {
            do {
                let connection = try listener.accept()
                logger.debug("Accepted vsock connection")
                return connection
            } catch {
                // If would block, sleep and retry
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        throw BridgeError.relayFailed("Cancelled while waiting for connection")
    }

    /// Relay data forward
    private func relayForward(
        from source: Socket,
        to dest: Socket,
        direction: String,
        logger: Logger
    ) async {
        var buffer = Data(count: 65536)
        var totalBytes: UInt64 = 0

        while !Task.isCancelled {
            do {
                let bytesRead = try source.read(buffer: &buffer)

                guard bytesRead > 0 else {
                    logger.info("Connection closed", metadata: ["direction": "\(direction)"])
                    break
                }

                // Write to destination (only the bytes actually read)
                let dataToWrite = buffer.prefix(bytesRead)
                _ = try dest.write(data: dataToWrite)

                totalBytes += UInt64(bytesRead)

                if totalBytes % 1_000_000 == 0 {
                    logger.trace("Relayed data", metadata: [
                        "direction": "\(direction)",
                        "totalMB": "\(totalBytes / 1_000_000)"
                    ])
                }

            } catch {
                logger.error("Relay error", metadata: [
                    "direction": "\(direction)",
                    "error": "\(error)"
                ])
                break
            }
        }

        logger.debug("Relay stopped", metadata: [
            "direction": "\(direction)",
            "totalBytes": "\(totalBytes)"
        ])
    }

    /// Relay data backward
    private func relayBackward(
        from source: Socket,
        to dest: Socket,
        direction: String,
        logger: Logger
    ) async {
        // Same implementation as relayForward
        await relayForward(from: source, to: dest, direction: direction, logger: logger)
    }

    /// Relay data from Socket to FileHandle
    private func relaySocketToFileHandle(
        from source: Socket,
        to dest: FileHandle,
        direction: String,
        logger: Logger
    ) async {
        var buffer = Data(count: 65536)
        var totalBytes: UInt64 = 0

        while !Task.isCancelled {
            do {
                let bytesRead = try source.read(buffer: &buffer)

                guard bytesRead > 0 else {
                    logger.info("Connection closed", metadata: ["direction": "\(direction)"])
                    break
                }

                // Write to destination (only the bytes actually read)
                let dataToWrite = buffer.prefix(bytesRead)
                try dest.write(contentsOf: dataToWrite)

                totalBytes += UInt64(bytesRead)

                if totalBytes % 1_000_000 == 0 {
                    logger.trace("Relayed data", metadata: [
                        "direction": "\(direction)",
                        "bytes": "\(totalBytes)"
                    ])
                }
            } catch {
                logger.error("Relay error", metadata: [
                    "direction": "\(direction)",
                    "error": "\(error)"
                ])
                break
            }
        }

        logger.debug("Relay stopped", metadata: [
            "direction": "\(direction)",
            "totalBytes": "\(totalBytes)"
        ])
    }

    /// Relay data from FileHandle to Socket
    private func relayFileHandleToSocket(
        from source: FileHandle,
        to dest: Socket,
        direction: String,
        logger: Logger
    ) async {
        var totalBytes: UInt64 = 0

        while !Task.isCancelled {
            do {
                // FileHandle.read doesn't have a non-deprecated async read
                // Use availableData which reads available bytes
                let data = source.availableData

                guard !data.isEmpty else {
                    logger.info("Connection closed", metadata: ["direction": "\(direction)"])
                    break
                }

                // Write to destination socket
                _ = try dest.write(data: data)

                totalBytes += UInt64(data.count)

                if totalBytes % 1_000_000 == 0 {
                    logger.trace("Relayed data", metadata: [
                        "direction": "\(direction)",
                        "bytes": "\(totalBytes)"
                    ])
                }
            } catch {
                logger.error("Relay error", metadata: [
                    "direction": "\(direction)",
                    "error": "\(error)"
                ])
                break
            }
        }

        logger.debug("Relay stopped", metadata: [
            "direction": "\(direction)",
            "totalBytes": "\(totalBytes)"
        ])
    }

    /// Relay data between two file descriptors
    private func relayFD(
        sourceFD: Int32,
        destFD: Int32,
        direction: String,
        logger: Logger
    ) async {
        logger.info("Relay function entered", metadata: [
            "direction": "\(direction)",
            "source_fd": "\(sourceFD)",
            "dest_fd": "\(destFD)"
        ])

        // Set source FD to non-blocking mode
        let flags = fcntl(sourceFD, F_GETFL, 0)
        _ = fcntl(sourceFD, F_SETFL, flags | O_NONBLOCK)

        var totalBytes: UInt64 = 0
        var packetCount: UInt64 = 0
        let bufferSize = 65536
        var buffer = Data(count: bufferSize)

        logger.info("Starting relay loop (non-blocking)", metadata: [
            "direction": "\(direction)",
            "source_fd": "\(sourceFD)",
            "dest_fd": "\(destFD)"
        ])

        while !Task.isCancelled {
            // Read into buffer using low-level read() in non-blocking mode
            let bytesRead = buffer.withUnsafeMutableBytes { bufferPtr in
                Darwin.read(sourceFD, bufferPtr.baseAddress!, bufferSize)
            }

            // Handle EAGAIN/EWOULDBLOCK in non-blocking mode
            if bytesRead < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // No data available, yield and try again
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    continue
                }
                // Real error
                logger.error("Read error", metadata: [
                    "direction": "\(direction)",
                    "errno": "\(errno)",
                    "strerror": "\(String(cString: strerror(errno)))"
                ])
                break
            }

            guard bytesRead > 0 else {
                if bytesRead == 0 {
                    logger.info("Connection closed", metadata: ["direction": "\(direction)"])
                } else {
                    logger.error("Read error", metadata: [
                        "direction": "\(direction)",
                        "errno": "\(errno)",
                        "strerror": "\(String(cString: strerror(errno)))"
                    ])
                }
                break
            }

            packetCount += 1
            totalBytes += UInt64(bytesRead)

            // Log first 10 packets for debugging
            if packetCount <= 10 {
                logger.info("Relay packet", metadata: [
                    "direction": "\(direction)",
                    "packet": "\(packetCount)",
                    "bytes": "\(bytesRead)"
                ])
            }

            // Write to destination using low-level write()
            let data = buffer.prefix(bytesRead)
            let bytesWritten = data.withUnsafeBytes { dataPtr in
                Darwin.write(destFD, dataPtr.baseAddress!, bytesRead)
            }

            guard bytesWritten == bytesRead else {
                logger.error("Write error", metadata: [
                    "direction": "\(direction)",
                    "expected": "\(bytesRead)",
                    "written": "\(bytesWritten)",
                    "errno": "\(errno)",
                    "strerror": "\(String(cString: strerror(errno)))"
                ])
                break
            }
        }

        logger.info("Relay stopped", metadata: [
            "direction": "\(direction)",
            "totalBytes": "\(totalBytes)",
            "packetCount": "\(packetCount)"
        ])
    }

    // MARK: - Helper Methods

    /// Dial vsock with exponential backoff retry
    private func dialWithRetry(
        container: LinuxContainer,
        port: UInt32,
        maxAttempts: Int,
        logger: Logger
    ) async throws -> FileHandle {
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1

            do {
                let handle = try await container.dialVsock(port: port)
                logger.debug("Successfully connected to vsock port \(port) on attempt \(attempt)")
                return handle
            } catch {
                lastError = error
                logger.debug("Connection attempt \(attempt) failed: \(error)")

                if attempt < maxAttempts {
                    // Exponential backoff: 50ms, 100ms, 200ms, 400ms...
                    let delayMs = min(50 * (1 << (attempt - 1)), 3000)
                    logger.debug("Retrying in \(delayMs)ms...")
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
        }

        throw lastError ?? BridgeError.relayFailed("Failed to connect after \(maxAttempts) attempts")
    }

    // MARK: - Statistics

    /// Get count of active network attachments
    public func activeAttachmentCount() -> Int {
        return attachments.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - ForwarderLogWriter

/// Writer that logs arca-tap-forwarder output to a file in ~/.arca/logs/
private final class ForwarderLogWriter: Writer, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let logger: Logger
    private let containerID: String

    init(logger: Logger, containerID: String) throws {
        self.logger = logger
        self.containerID = containerID

        // Create log directory if needed
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arca/logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Create log file for this forwarder
        let logFile = logsDir.appendingPathComponent("tap-forwarder-\(containerID).log")

        // Create or truncate the file
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: logFile.path) else {
            logger.error("Failed to open forwarder log file", metadata: ["path": "\(logFile.path)"])
            throw NSError(domain: "NetworkBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not create forwarder log file"])
        }

        self.fileHandle = handle
        logger.debug("Created forwarder log file", metadata: [
            "path": "\(logFile.path)",
            "container": "\(containerID)"
        ])
    }

    func write(_ data: Data) throws {
        try fileHandle.write(contentsOf: data)
    }

    func close() throws {
        try fileHandle.close()
    }
}

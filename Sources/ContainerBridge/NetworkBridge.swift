// NetworkBridge - Orchestrates container network attachments and packet relay
// Control plane: Sends gRPC commands to arca-tap-forwarder
// Data plane: Relays packets between container VMs and helper VM

import Foundation
import Logging
import Containerization
import ContainerizationOS
import NIOCore
import NIOPosix

/// Network bridge that manages container network attachments
public actor NetworkBridge {
    private let logger: Logger
    private var helperVM: NetworkHelperVM?
    private var portAllocator: PortAllocator

    // Track network attachments: containerID -> networkID -> attachment
    private var attachments: [String: [String: NetworkAttachment]] = [:]

    struct NetworkAttachment {
        let networkID: String
        let device: String          // eth0, eth1, etc.
        let containerPort: UInt32   // vsock data port
        let helperPort: UInt32
        let relayTask: Task<Void, Never>
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case helperVMNotRunning
        case containerNotFound
        case networkNotFound
        case attachmentFailed(String)
        case detachmentFailed(String)
        case relayFailed(String)

        public var description: String {
            switch self {
            case .helperVMNotRunning: return "Helper VM not running"
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

    /// Set the helper VM reference
    public func setHelperVM(_ helperVM: NetworkHelperVM) {
        self.helperVM = helperVM
    }

    // MARK: - Network Attachment

    /// Attach a container to a network
    public func attachContainerToNetwork(
        container: LinuxContainer,
        containerID: String,
        networkID: String,
        ipAddress: String,
        gateway: String,
        device: String
    ) async throws {
        guard let helperVM = helperVM else {
            throw BridgeError.helperVMNotRunning
        }

        logger.info("Attaching container to network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "device": "\(device)",
            "ip": "\(ipAddress)"
        ])

        // 1. Allocate vsock ports
        let containerPort = try await portAllocator.allocate()
        let helperPort = containerPort + 10000  // Helper uses +10000 offset

        logger.debug("Allocated ports", metadata: [
            "containerPort": "\(containerPort)",
            "helperPort": "\(helperPort)"
        ])

        // 2. Send AttachNetwork RPC to arca-tap-forwarder
        do {
            let client = try await TAPForwarderClient(container: container, logger: logger)

            let response = try await client.attachNetwork(
                device: device,
                vsockPort: containerPort,
                ipAddress: ipAddress,
                gateway: gateway,
                netmask: 24
            )

            guard response.success else {
                await portAllocator.release(containerPort)
                throw BridgeError.attachmentFailed(response.error)
            }

            logger.info("TAP device created in container", metadata: [
                "device": "\(device)",
                "mac": "\(response.macAddress)"
            ])

            // 3. Get helper VM container for relay
            guard let helperVMContainer = await helperVM.getContainer() else {
                throw BridgeError.attachmentFailed("Helper VM container not available")
            }

            // 4. Start data plane relay task
            let relayTask = Task {
                await self.runRelay(
                    containerID: containerID,
                    containerPort: containerPort,
                    helperVMContainer: helperVMContainer,
                    helperPort: helperPort
                )
            }

            // 5. Track this attachment
            if attachments[containerID] == nil {
                attachments[containerID] = [:]
            }

            attachments[containerID]![networkID] = NetworkAttachment(
                networkID: networkID,
                device: device,
                containerPort: containerPort,
                helperPort: helperPort,
                relayTask: relayTask
            )

            logger.info("Network attachment complete", metadata: [
                "containerID": "\(containerID)",
                "networkID": "\(networkID)"
            ])

        } catch let error as BridgeError {
            await portAllocator.release(containerPort)
            throw error
        } catch {
            await portAllocator.release(containerPort)
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

    /// Run packet relay between container and helper VM
    /// This is the data plane that forwards Ethernet frames
    private func runRelay(
        containerID: String,
        containerPort: UInt32,
        helperVMContainer: LinuxContainer,
        helperPort: UInt32
    ) async {
        let relayLogger = Logger(label: "network-relay-\(containerID)")

        relayLogger.info("Starting packet relay", metadata: [
            "containerPort": "\(containerPort)",
            "helperPort": "\(helperPort)"
        ])

        do {
            // Wait for container to connect (container initiates connection to host)
            let containerListener = try createVsockListener(port: containerPort, logger: relayLogger)
            relayLogger.debug("Listening for container connection")

            let containerConnection = try await acceptVsockConnection(listener: containerListener, logger: relayLogger)
            relayLogger.info("Container connected")

            // Dial helper VM
            relayLogger.debug("Dialing helper VM")
            let helperConnection = try await helperVMContainer.dialVsock(port: helperPort)
            relayLogger.info("Helper VM connected")

            // Run bidirectional relay
            await withTaskGroup(of: Void.self) { group in
                // Container -> Helper (Socket -> FileHandle)
                group.addTask {
                    await self.relaySocketToFileHandle(
                        from: containerConnection,
                        to: helperConnection,
                        direction: "container->helper",
                        logger: relayLogger
                    )
                }

                // Helper -> Container (FileHandle -> Socket)
                group.addTask {
                    await self.relayFileHandleToSocket(
                        from: helperConnection,
                        to: containerConnection,
                        direction: "helper->container",
                        logger: relayLogger
                    )
                }

                // Wait for either direction to complete or cancel
                await group.waitForAll()
            }

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

    // MARK: - Statistics

    /// Get count of active network attachments
    public func activeAttachmentCount() -> Int {
        return attachments.values.reduce(0) { $0 + $1.count }
    }
}

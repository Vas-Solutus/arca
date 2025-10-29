// TAPForwarderClient - gRPC client for communicating with arca-tap-forwarder daemon
// Sends network attach/detach commands to containers over vsock

import Foundation
import Logging
import GRPC
import NIOCore
import NIOPosix
import Containerization

/// Client for communicating with arca-tap-forwarder daemon running in a container
public actor TAPForwarderClient {
    private let container: LinuxContainer
    private let logger: Logger
    private var client: Arca_Tapforwarder_V1_TAPForwarderNIOClient?
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    private static let CONTROL_PORT: UInt32 = 5555

    public enum ClientError: Error, CustomStringConvertible {
        case dialFailed(String)
        case notConnected
        case rpcFailed(String)

        public var description: String {
            switch self {
            case .dialFailed(let msg): return "Failed to dial container: \(msg)"
            case .notConnected: return "Client not connected"
            case .rpcFailed(let msg): return "RPC failed: \(msg)"
            }
        }
    }

    public init(container: LinuxContainer, logger: Logger) async throws {
        self.container = container
        self.logger = logger

        try await connect()
    }

    private func connect() async throws {
        logger.debug("Connecting to arca-tap-forwarder via vsock", metadata: [
            "containerID": "\(container.id)",
            "port": "\(Self.CONTROL_PORT)"
        ])

        // Retry connection with exponential backoff
        // The forwarder needs time to start up and bind to vsock port
        let maxAttempts = 10
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1

            do {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                self.eventLoopGroup = group

                let fileHandle = try await container.dialVsock(port: Self.CONTROL_PORT)
                logger.debug("dialVsock successful", metadata: [
                    "fd": "\(fileHandle.fileDescriptor)",
                    "attempt": "\(attempt)"
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
                self.client = Arca_Tapforwarder_V1_TAPForwarderNIOClient(channel: channel)

                logger.info("Connected to arca-tap-forwarder via vsock", metadata: [
                    "attempt": "\(attempt)"
                ])
                return
            } catch {
                lastError = error
                logger.debug("Connection attempt \(attempt) failed", metadata: [
                    "error": "\(error)"
                ])

                // Clean up event loop group if it was created
                try? await eventLoopGroup?.shutdownGracefully()
                eventLoopGroup = nil

                if attempt < maxAttempts {
                    // Exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms, 1600ms, 3200ms...
                    let delayMs = min(50 * (1 << (attempt - 1)), 3000)
                    logger.debug("Retrying in \(delayMs)ms...")
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
        }

        // All attempts failed
        logger.error("Failed to connect to arca-tap-forwarder after \(maxAttempts) attempts", metadata: [
            "error": "\(lastError?.localizedDescription ?? "unknown")"
        ])
        throw ClientError.dialFailed(lastError?.localizedDescription ?? "Connection failed after \(maxAttempts) attempts")
    }

    public func attachNetwork(
        device: String,
        vsockPort: UInt32,
        ipAddress: String,
        gateway: String,
        netmask: UInt32 = 24,
        macAddress: String
    ) async throws -> Arca_Tapforwarder_V1_AttachNetworkResponse {
        guard let client = client else {
            throw ClientError.notConnected
        }

        var request = Arca_Tapforwarder_V1_AttachNetworkRequest()
        request.device = device
        request.vsockPort = vsockPort
        request.ipAddress = ipAddress
        request.gateway = gateway
        request.netmask = netmask
        request.macAddress = macAddress // Set MAC address to ensure it matches OVN port_security

        logger.info("Sending AttachNetwork RPC", metadata: [
            "device": "\(device)",
            "vsockPort": "\(vsockPort)",
            "ip": "\(ipAddress)"
        ])

        do {
            let response = try await client.attachNetwork(request).response.get()

            if response.success {
                logger.info("Network attached successfully", metadata: [
                    "device": "\(device)",
                    "mac": "\(response.macAddress)"
                ])
            } else {
                logger.error("Network attach failed", metadata: ["error": "\(response.error)"])
            }

            return response
        } catch {
            logger.error("AttachNetwork RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func detachNetwork(device: String) async throws -> Arca_Tapforwarder_V1_DetachNetworkResponse {
        guard let client = client else {
            throw ClientError.notConnected
        }

        var request = Arca_Tapforwarder_V1_DetachNetworkRequest()
        request.device = device

        logger.info("Sending DetachNetwork RPC", metadata: ["device": "\(device)"])

        do {
            let response = try await client.detachNetwork(request).response.get()

            if response.success {
                logger.info("Network detached successfully", metadata: ["device": "\(device)"])
            } else {
                logger.error("Network detach failed", metadata: ["error": "\(response.error)"])
            }

            return response
        } catch {
            logger.error("DetachNetwork RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func listNetworks() async throws -> Arca_Tapforwarder_V1_ListNetworksResponse {
        guard let client = client else {
            throw ClientError.notConnected
        }

        let request = Arca_Tapforwarder_V1_ListNetworksRequest()

        do {
            let response = try await client.listNetworks(request).response.get()
            logger.debug("ListNetworks returned \(response.networks.count) networks")
            return response
        } catch {
            logger.error("ListNetworks RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func getStatus() async throws -> Arca_Tapforwarder_V1_GetStatusResponse {
        guard let client = client else {
            throw ClientError.notConnected
        }

        let request = Arca_Tapforwarder_V1_GetStatusRequest()

        do {
            let response = try await client.getStatus(request).response.get()
            logger.debug("GetStatus: \(response.activeNetworks) active networks")
            return response
        } catch {
            logger.error("GetStatus RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateDNSMappings(
        networks: [String: Arca_Tapforwarder_V1_NetworkPeers]
    ) async throws -> Arca_Tapforwarder_V1_UpdateDNSMappingsResponse {
        guard let client = client else {
            throw ClientError.notConnected
        }

        var request = Arca_Tapforwarder_V1_UpdateDNSMappingsRequest()
        request.networks = networks

        logger.debug("Sending UpdateDNSMappings RPC", metadata: [
            "networkCount": "\(networks.count)"
        ])

        do {
            let response = try await client.updateDNSMappings(request).response.get()

            if response.success {
                logger.debug("DNS mappings updated successfully", metadata: [
                    "records": "\(response.recordsUpdated)"
                ])
            } else {
                logger.error("DNS mappings update failed", metadata: ["error": "\(response.error)"])
            }

            return response
        } catch {
            logger.error("UpdateDNSMappings RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func close() async {
        if let channel = channel {
            try? await channel.close().get()
        }
        try? await eventLoopGroup?.shutdownGracefully()

        if let fileHandle = vsockFileHandle {
            try? fileHandle.close()
        }

        client = nil
        channel = nil
        eventLoopGroup = nil
        vsockFileHandle = nil
    }
}

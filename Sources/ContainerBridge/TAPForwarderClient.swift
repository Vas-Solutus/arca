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
    private var client: Arca_Tapforwarder_V1_TAPForwarderAsyncClient?
    private var channel: GRPCChannel?

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
        logger.debug("Connecting to arca-tap-forwarder", metadata: [
            "containerID": "\(container.id)",
            "port": "\(Self.CONTROL_PORT)"
        ])

        // Dial the container's arca-tap-forwarder via vsock
        // The forwarder listens on localhost:5555, and we connect via vsock forwarding
        do {
            let stream = try await container.dialVsock(port: Self.CONTROL_PORT)

            // Create NIO channel from the stream
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            // For now, use a simple TCP connection approach
            // TODO: Integrate with vsock stream properly
            let channel = try GRPCChannelPool.with(
                target: .host("127.0.0.1", port: Int(Self.CONTROL_PORT)),
                transportSecurity: .plaintext,
                eventLoopGroup: group
            )

            self.channel = channel
            self.client = Arca_Tapforwarder_V1_TAPForwarderAsyncClient(channel: channel)

            logger.info("Connected to arca-tap-forwarder")
        } catch {
            logger.error("Failed to connect to arca-tap-forwarder", metadata: ["error": "\(error)"])
            throw ClientError.dialFailed(error.localizedDescription)
        }
    }

    public func attachNetwork(
        device: String,
        vsockPort: UInt32,
        ipAddress: String,
        gateway: String,
        netmask: UInt32 = 24
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

        logger.info("Sending AttachNetwork RPC", metadata: [
            "device": "\(device)",
            "vsockPort": "\(vsockPort)",
            "ip": "\(ipAddress)"
        ])

        do {
            let response = try await client.attachNetwork(request)

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
            let response = try await client.detachNetwork(request)

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
            let response = try await client.listNetworks(request)
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
            let response = try await client.getStatus(request)
            logger.debug("GetStatus: \(response.activeNetworks) active networks")
            return response
        } catch {
            logger.error("GetStatus RPC failed", metadata: ["error": "\(error)"])
            throw ClientError.rpcFailed(error.localizedDescription)
        }
    }

    public func close() async {
        if let channel = channel {
            try? await channel.close().get()
        }
        client = nil
        channel = nil
    }
}

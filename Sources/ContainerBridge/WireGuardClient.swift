import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// WireGuardClient handles gRPC communication with the container's WireGuard service via vsock
public actor WireGuardClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Wireguard_V1_WireGuardServiceNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum WireGuardClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case operationFailed(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "WireGuard client not connected to container"
            case .connectionFailed(let reason):
                return "Failed to connect to container: \(reason)"
            case .operationFailed(let reason):
                return "WireGuard operation failed: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.network.wireguard")
    }

    /// Connect to a container's WireGuard service via vsock using LinuxContainer.dialVsock()
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 51820) async throws {
        logger.info("Connecting to container WireGuard service via vsock", metadata: [
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
        self.client = Arca_Wireguard_V1_WireGuardServiceNIOClient(channel: channel)

        logger.info("Connected to container WireGuard service via vsock")
    }

    /// Disconnect from the container's WireGuard service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from container WireGuard service")

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

        logger.info("Disconnected from container WireGuard service")
    }

    /// Create a WireGuard hub (wg0) interface in the container
    public func createHub(
        privateKey: String,
        listenPort: UInt32,
        ipAddress: String,
        networkCIDR: String
    ) async throws -> String {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Creating WireGuard hub", metadata: [
            "listenPort": "\(listenPort)",
            "ipAddress": "\(ipAddress)",
            "networkCIDR": "\(networkCIDR)"
        ])

        var request = Arca_Wireguard_V1_CreateHubRequest()
        request.privateKey = privateKey
        request.listenPort = listenPort
        request.ipAddress = ipAddress
        request.networkCidr = networkCIDR

        let call = client.createHub(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("WireGuard hub created successfully", metadata: [
            "publicKey": "\(response.publicKey)",
            "interface": "\(response.interface)"
        ])
        return response.publicKey
    }

    /// Add a network to the container's WireGuard hub
    public func addNetwork(
        networkID: String,
        peerEndpoint: String,
        peerPublicKey: String,
        ipAddress: String,
        networkCIDR: String,
        gateway: String
    ) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Adding network to WireGuard hub", metadata: [
            "networkID": "\(networkID)",
            "peerEndpoint": "\(peerEndpoint)",
            "ipAddress": "\(ipAddress)",
            "networkCIDR": "\(networkCIDR)",
            "gateway": "\(gateway)"
        ])

        var request = Arca_Wireguard_V1_AddNetworkRequest()
        request.networkID = networkID
        request.peerEndpoint = peerEndpoint
        request.peerPublicKey = peerPublicKey
        request.ipAddress = ipAddress
        request.networkCidr = networkCIDR
        request.gateway = gateway

        let call = client.addNetwork(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Network added to WireGuard hub successfully", metadata: [
            "totalNetworks": "\(response.totalNetworks)"
        ])
    }

    /// Remove a network from the container's WireGuard hub
    public func removeNetwork(networkID: String) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Removing network from WireGuard hub", metadata: [
            "networkID": "\(networkID)"
        ])

        var request = Arca_Wireguard_V1_RemoveNetworkRequest()
        request.networkID = networkID

        let call = client.removeNetwork(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Network removed from WireGuard hub successfully", metadata: [
            "remainingNetworks": "\(response.remainingNetworks)"
        ])
    }

    /// Update allowed IPs for multi-network routing
    public func updateAllowedIPs(peerPublicKey: String, allowedCIDRs: [String]) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Updating allowed IPs", metadata: [
            "peerPublicKey": "\(peerPublicKey)",
            "allowedCIDRs": "\(allowedCIDRs.joined(separator: ", "))"
        ])

        var request = Arca_Wireguard_V1_UpdateAllowedIPsRequest()
        request.peerPublicKey = peerPublicKey
        request.allowedCidrs = allowedCIDRs

        let call = client.updateAllowedIPs(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Allowed IPs updated successfully", metadata: [
            "totalAllowed": "\(response.totalAllowed)"
        ])
    }

    /// Delete the WireGuard hub interface
    public func deleteHub(force: Bool = false) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Deleting WireGuard hub", metadata: ["force": "\(force)"])

        var request = Arca_Wireguard_V1_DeleteHubRequest()
        request.force = force

        let call = client.deleteHub(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("WireGuard hub deleted successfully")
    }

    /// Get WireGuard hub status and statistics
    public func getStatus() async throws -> Arca_Wireguard_V1_GetStatusResponse {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        let request = Arca_Wireguard_V1_GetStatusRequest()
        let call = client.getStatus(request)
        let response = try await call.response.get()

        logger.debug("WireGuard status", metadata: [
            "version": "\(response.version)",
            "networkCount": "\(response.networkCount)",
            "interface": response.hasInterface ? "\(response.interface.name)" : "none"
        ])

        return response
    }
}

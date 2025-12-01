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
    // Note: SwiftNIO takes ownership of the file descriptor when using .connectedSocket()
    // We must NOT keep the FileHandle alive as it would cause dual ownership and crashes

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
        let fd = fileHandle.fileDescriptor
        logger.debug("container.dialVsock() successful, got file handle", metadata: [
            "fd": "\(fd)"
        ])

        // Create gRPC channel from the connected socket
        // IMPORTANT: SwiftNIO takes ownership of the fd via .connectedSocket()
        // We must NOT keep the FileHandle alive - SwiftNIO will close the fd when channel closes
        let channel = ClientConnection(
            configuration: .default(
                target: .connectedSocket(NIOBSDSocket.Handle(fd)),
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

        // Close the gRPC channel - SwiftNIO will automatically close the underlying fd
        try await channel.close().get()
        try await eventLoopGroup?.shutdownGracefully()

        self.channel = nil
        self.eventLoopGroup = nil
        self.client = nil

        logger.info("Disconnected from container WireGuard service")
    }

    /// Add a network to the container's WireGuard hub (creates wgN/ethN interfaces)
    /// Hub is created lazily on first network addition
    public func addNetwork(
        networkID: String,
        networkIndex: UInt32,
        privateKey: String,
        listenPort: UInt32,
        peerEndpoint: String,
        peerPublicKey: String,
        ipAddress: String,
        networkCIDR: String,
        gateway: String,
        hostIP: String,
        extraHosts: [String] = []
    ) async throws -> (wgInterface: String, ethInterface: String, publicKey: String) {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Adding network to WireGuard hub", metadata: [
            "networkID": "\(networkID)",
            "networkIndex": "\(networkIndex)",
            "listenPort": "\(listenPort)",
            "peerEndpoint": "\(peerEndpoint)",
            "ipAddress": "\(ipAddress)",
            "networkCIDR": "\(networkCIDR)",
            "gateway": "\(gateway)",
            "hostIP": "\(hostIP)",
            "extraHostsCount": "\(extraHosts.count)"
        ])

        var request = Arca_Wireguard_V1_AddNetworkRequest()
        request.networkID = networkID
        request.networkIndex = networkIndex
        request.privateKey = privateKey
        request.listenPort = listenPort
        request.peerEndpoint = peerEndpoint
        request.peerPublicKey = peerPublicKey
        request.ipAddress = ipAddress
        request.networkCidr = networkCIDR
        request.gateway = gateway
        request.hostIp = hostIP
        request.extraHosts = extraHosts

        let call = client.addNetwork(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Network added to WireGuard hub successfully", metadata: [
            "totalNetworks": "\(response.totalNetworks)",
            "wgInterface": "\(response.wgInterface)",
            "ethInterface": "\(response.ethInterface)",
            "publicKey": "\(response.publicKey)"
        ])

        return (response.wgInterface, response.ethInterface, response.publicKey)
    }

    /// Remove a network from the container's WireGuard hub (deletes wgN/ethN interfaces)
    public func removeNetwork(networkID: String, networkIndex: UInt32) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Removing network from WireGuard hub", metadata: [
            "networkID": "\(networkID)",
            "networkIndex": "\(networkIndex)"
        ])

        var request = Arca_Wireguard_V1_RemoveNetworkRequest()
        request.networkID = networkID
        request.networkIndex = networkIndex

        let call = client.removeNetwork(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Network removed from WireGuard hub successfully", metadata: [
            "remainingNetworks": "\(response.remainingNetworks)"
        ])
    }

    /// Add a peer to a WireGuard interface (for full mesh networking + DNS registration)
    public func addPeer(
        networkID: String,
        networkIndex: UInt32,
        peerPublicKey: String,
        peerEndpoint: String,
        peerIPAddress: String,
        peerName: String,
        peerContainerID: String,
        peerAliases: [String] = []
    ) async throws -> UInt32 {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Adding peer to WireGuard interface", metadata: [
            "networkID": "\(networkID)",
            "networkIndex": "\(networkIndex)",
            "peerEndpoint": "\(peerEndpoint)",
            "peerIPAddress": "\(peerIPAddress)",
            "peerName": "\(peerName)"
        ])

        var request = Arca_Wireguard_V1_AddPeerRequest()
        request.networkID = networkID
        request.networkIndex = networkIndex
        request.peerPublicKey = peerPublicKey
        request.peerEndpoint = peerEndpoint
        request.peerIpAddress = peerIPAddress
        request.peerName = peerName
        request.peerContainerID = peerContainerID
        request.peerAliases = peerAliases

        let call = client.addPeer(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Peer added to WireGuard interface successfully (DNS registered)", metadata: [
            "totalPeers": "\(response.totalPeers)"
        ])

        return response.totalPeers
    }

    /// Remove a peer from a WireGuard interface (also removes DNS entry)
    public func removePeer(
        networkID: String,
        networkIndex: UInt32,
        peerPublicKey: String,
        peerName: String
    ) async throws -> UInt32 {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Removing peer from WireGuard interface", metadata: [
            "networkID": "\(networkID)",
            "networkIndex": "\(networkIndex)",
            "peerName": "\(peerName)"
        ])

        var request = Arca_Wireguard_V1_RemovePeerRequest()
        request.networkID = networkID
        request.networkIndex = networkIndex
        request.peerPublicKey = peerPublicKey
        request.peerName = peerName

        let call = client.removePeer(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Peer removed from WireGuard interface successfully (DNS unregistered)", metadata: [
            "remainingPeers": "\(response.remainingPeers)"
        ])

        return response.remainingPeers
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
            "interfaces": "\(response.interfaces.map { $0.name }.joined(separator: ", "))"
        ])

        return response
    }

    /// Get the container's vmnet endpoint (eth0 IP:port) for peer configuration
    public func getVmnetEndpoint() async throws -> String {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.debug("Getting vmnet endpoint from container")

        let request = Arca_Wireguard_V1_GetVmnetEndpointRequest()
        let call = client.getVmnetEndpoint(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Got vmnet endpoint", metadata: ["endpoint": "\(response.endpoint)"])
        return response.endpoint
    }

    /// Publish a port (Phase 4.1)
    /// Creates DNAT and INPUT rules to expose container port on vmnet interface
    public func publishPort(
        proto: String,
        hostPort: UInt32,
        containerIP: String,
        containerPort: UInt32
    ) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Publishing port via WireGuard gRPC", metadata: [
            "protocol": "\(proto)",
            "hostPort": "\(hostPort)",
            "containerIP": "\(containerIP)",
            "containerPort": "\(containerPort)"
        ])

        var request = Arca_Wireguard_V1_PublishPortRequest()
        request.`protocol` = proto
        request.hostPort = hostPort
        request.containerIp = containerIP
        request.containerPort = containerPort

        let call = client.publishPort(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Port published successfully via WireGuard gRPC", metadata: [
            "protocol": "\(proto)",
            "hostPort": "\(hostPort)"
        ])
    }

    /// Unpublish a port (Phase 4.1)
    /// Removes DNAT and INPUT rules for published port
    public func unpublishPort(
        proto: String,
        hostPort: UInt32
    ) async throws {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.info("Unpublishing port via WireGuard gRPC", metadata: [
            "protocol": "\(proto)",
            "hostPort": "\(hostPort)"
        ])

        var request = Arca_Wireguard_V1_UnpublishPortRequest()
        request.`protocol` = proto
        request.hostPort = hostPort

        let call = client.unpublishPort(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        logger.info("Port unpublished successfully via WireGuard gRPC", metadata: [
            "protocol": "\(proto)",
            "hostPort": "\(hostPort)"
        ])
    }

    /// Dump nftables ruleset for debugging (Phase 4.1)
    /// Returns full nftables ruleset with packet counters
    public func dumpNftables() async throws -> String {
        guard let client = client else {
            throw WireGuardClientError.notConnected
        }

        logger.debug("Dumping nftables ruleset from container")

        let request = Arca_Wireguard_V1_DumpNftablesRequest()
        let call = client.dumpNftables(request)
        let response = try await call.response.get()

        guard response.success else {
            throw WireGuardClientError.operationFailed(response.error)
        }

        return response.ruleset
    }
}

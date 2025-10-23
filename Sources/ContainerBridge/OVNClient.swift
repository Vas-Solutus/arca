import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// OVNClient handles gRPC communication with the helper VM's control API via vsock
public actor OVNClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Network_NetworkControlNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum OVNClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case operationFailed(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "OVN client not connected to helper VM"
            case .connectionFailed(let reason):
                return "Failed to connect to helper VM: \(reason)"
            case .operationFailed(let reason):
                return "OVN operation failed: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.network.ovnclient")
    }

    /// Connect to the helper VM via vsock using LinuxContainer.dialVsock()
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 9999) async throws {
        logger.info("Connecting to helper VM via vsock (LinuxContainer.dialVsock())", metadata: [
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
        self.client = Arca_Network_NetworkControlNIOClient(channel: channel)

        logger.info("Connected to helper VM control API via vsock")
    }

    /// Disconnect from the helper VM
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from helper VM")

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

        logger.info("Disconnected from helper VM")
    }

    /// Create a new OVS bridge and OVN logical switch
    public func createBridge(networkID: String, subnet: String, gateway: String) async throws -> String {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Creating bridge", metadata: [
            "networkID": "\(networkID)",
            "subnet": "\(subnet)",
            "gateway": "\(gateway)"
        ])

        var request = Arca_Network_CreateBridgeRequest()
        request.networkID = networkID
        request.subnet = subnet
        request.gateway = gateway

        let call = client.createBridge(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Bridge created successfully", metadata: ["bridgeName": "\(response.bridgeName)"])
        return response.bridgeName
    }

    /// Delete an OVS bridge and OVN logical switch
    public func deleteBridge(networkID: String) async throws {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Deleting bridge", metadata: ["networkID": "\(networkID)"])

        var request = Arca_Network_DeleteBridgeRequest()
        request.networkID = networkID

        let call = client.deleteBridge(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Bridge deleted successfully")
    }

    /// Attach a container to a network
    public func attachContainer(
        containerID: String,
        networkID: String,
        ipAddress: String,
        macAddress: String,
        hostname: String,
        aliases: [String] = [],
        vsockPort: UInt32
    ) async throws -> String {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Attaching container to network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "ip": "\(ipAddress)",
            "mac": "\(macAddress)",
            "vsockPort": "\(vsockPort)"
        ])

        var request = Arca_Network_AttachContainerRequest()
        request.containerID = containerID
        request.networkID = networkID
        request.ipAddress = ipAddress
        request.macAddress = macAddress
        request.hostname = hostname
        request.aliases = aliases
        request.vsockPort = vsockPort

        let call = client.attachContainer(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Container attached successfully", metadata: ["portName": "\(response.portName)"])
        return response.portName
    }

    /// Detach a container from a network
    public func detachContainer(containerID: String, networkID: String) async throws {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Detaching container from network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)"
        ])

        var request = Arca_Network_DetachContainerRequest()
        request.containerID = containerID
        request.networkID = networkID

        let call = client.detachContainer(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Container detached successfully")
    }

    /// List all bridges
    public func listBridges() async throws -> [Arca_Network_BridgeInfo] {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Listing bridges")

        let request = Arca_Network_ListBridgesRequest()
        let call = client.listBridges(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Retrieved bridge list", metadata: ["count": "\(response.bridges.count)"])
        return response.bridges
    }

    /// Set network policies for a network
    public func setNetworkPolicy(networkID: String, rules: [Arca_Network_NetworkPolicyRule]) async throws {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        logger.info("Setting network policy", metadata: [
            "networkID": "\(networkID)",
            "ruleCount": "\(rules.count)"
        ])

        var request = Arca_Network_SetNetworkPolicyRequest()
        request.networkID = networkID
        request.rules = rules

        let call = client.setNetworkPolicy(request)
        let response = try await call.response.get()

        guard response.success else {
            throw OVNClientError.operationFailed(response.error)
        }

        logger.info("Network policy set successfully")
    }

    /// Get health status of helper VM
    public func getHealth() async throws -> Arca_Network_GetHealthResponse {
        guard let client = client else {
            throw OVNClientError.notConnected
        }

        let request = Arca_Network_GetHealthRequest()
        let call = client.getHealth(request)
        let response = try await call.response.get()

        logger.debug("Health check", metadata: [
            "healthy": "\(response.healthy)",
            "ovsStatus": "\(response.ovsStatus)",
            "ovnStatus": "\(response.ovnStatus)",
            "uptime": "\(response.uptimeSeconds)s"
        ])

        return response
    }
}

import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// NetworkConfigClient handles gRPC communication with the VLAN service running inside container VMs.
/// This service manages VLAN interfaces and network configuration within each container's Linux VM via netlink.
public actor NetworkConfigClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Vlan_NetworkConfigNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum NetworkConfigClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case operationFailed(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "NetworkConfig client not connected to container VM"
            case .connectionFailed(let reason):
                return "Failed to connect to container VM: \(reason)"
            case .operationFailed(let reason):
                return "NetworkConfig operation failed: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.network.configclient")
    }

    /// Connect to the VLAN service running in the container VM via vsock.
    /// The service listens on vsock port 50051 by default.
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 50051) async throws {
        logger.info("Connecting to VLAN service via vsock (LinuxContainer.dialVsock())", metadata: [
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
        self.client = Vlan_NetworkConfigNIOClient(channel: channel)

        logger.info("Connected to VLAN service via vsock")
    }

    /// Disconnect from the container VM VLAN service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from VLAN service")

        try await channel.close().get()
        try await eventLoopGroup?.shutdownGracefully()

        self.channel = nil
        self.client = nil
        self.eventLoopGroup = nil
        self.vsockFileHandle = nil
    }

    // MARK: - VLAN Operations

    /// Create a VLAN interface in the container VM.
    ///
    /// - Parameters:
    ///   - parentInterface: Parent network interface (e.g., "eth0")
    ///   - vlanID: VLAN ID (1-4094)
    ///   - ipAddress: IP address in CIDR notation (e.g., "172.18.0.2/16")
    ///   - gateway: Gateway IP address (e.g., "172.18.0.1")
    ///   - mtu: MTU size (default: 1500, 0 = use parent's MTU)
    ///
    /// - Returns: Created interface name (e.g., "eth0.100")
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func createVLAN(
        parentInterface: String,
        vlanID: UInt32,
        ipAddress: String,
        gateway: String,
        mtu: UInt32 = 0
    ) async throws -> String {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_CreateVLANRequest()
        request.parentInterface = parentInterface
        request.vlanID = vlanID
        request.ipAddress = ipAddress
        request.gateway = gateway
        request.mtu = mtu

        logger.info("Creating VLAN interface", metadata: [
            "parent": "\(parentInterface)",
            "vlan_id": "\(vlanID)",
            "ip": "\(ipAddress)",
            "gateway": "\(gateway)"
        ])

        let response = try await client.createVLAN(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            logger.error("Failed to create VLAN interface", metadata: [
                "vlan_id": "\(vlanID)",
                "error": "\(error)"
            ])
            throw NetworkConfigClientError.operationFailed(error)
        }

        logger.info("VLAN interface created successfully", metadata: [
            "vlan_id": "\(vlanID)",
            "interface": "\(response.interfaceName)"
        ])

        return response.interfaceName
    }

    /// Delete a VLAN interface from the container VM.
    ///
    /// - Parameter interfaceName: Interface name to delete (e.g., "eth0.100")
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func deleteVLAN(interfaceName: String) async throws {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_DeleteVLANRequest()
        request.interfaceName = interfaceName

        logger.info("Deleting VLAN interface", metadata: [
            "interface": "\(interfaceName)"
        ])

        let response = try await client.deleteVLAN(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            logger.error("Failed to delete VLAN interface", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(error)"
            ])
            throw NetworkConfigClientError.operationFailed(error)
        }

        logger.info("VLAN interface deleted successfully", metadata: [
            "interface": "\(interfaceName)"
        ])
    }

    /// Configure IP address on an interface.
    ///
    /// - Parameters:
    ///   - interfaceName: Interface name (e.g., "eth0.100")
    ///   - ipAddress: IP address in CIDR notation (e.g., "172.18.0.2/16")
    ///   - replace: If true, replaces all existing IPs; if false, adds to existing (default: false)
    ///
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func configureIP(
        interfaceName: String,
        ipAddress: String,
        replace: Bool = false
    ) async throws {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_ConfigureIPRequest()
        request.interfaceName = interfaceName
        request.ipAddress = ipAddress
        request.replace = replace

        let response = try await client.configureIP(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw NetworkConfigClientError.operationFailed(error)
        }
    }

    /// Add a route to the routing table.
    ///
    /// - Parameters:
    ///   - destination: Destination network in CIDR notation (e.g., "0.0.0.0/0" for default route)
    ///   - gateway: Gateway IP address
    ///   - interfaceName: Interface to route through (optional)
    ///   - metric: Route metric/priority (default: 0 = system default)
    ///
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func addRoute(
        destination: String,
        gateway: String,
        interfaceName: String? = nil,
        metric: UInt32 = 0
    ) async throws {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_AddRouteRequest()
        request.destination = destination
        request.gateway = gateway
        if let iface = interfaceName {
            request.interfaceName = iface
        }
        request.metric = metric

        let response = try await client.addRoute(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw NetworkConfigClientError.operationFailed(error)
        }
    }

    /// Delete a route from the routing table.
    ///
    /// - Parameters:
    ///   - destination: Destination network in CIDR notation
    ///   - gateway: Gateway IP address (optional)
    ///   - interfaceName: Interface name (optional)
    ///
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func deleteRoute(
        destination: String,
        gateway: String? = nil,
        interfaceName: String? = nil
    ) async throws {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_DeleteRouteRequest()
        request.destination = destination
        if let gw = gateway {
            request.gateway = gw
        }
        if let iface = interfaceName {
            request.interfaceName = iface
        }

        let response = try await client.deleteRoute(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw NetworkConfigClientError.operationFailed(error)
        }
    }

    /// List all network interfaces in the container VM.
    ///
    /// - Parameter nameFilter: Optional filter by interface name pattern
    /// - Returns: Array of interface information (name, IP addresses, state, MTU)
    /// - Throws: NetworkConfigClientError if not connected or operation fails
    public func listInterfaces(nameFilter: String? = nil) async throws -> [Vlan_NetworkInterface] {
        guard let client = client else {
            throw NetworkConfigClientError.notConnected
        }

        var request = Vlan_ListInterfacesRequest()
        if let filter = nameFilter {
            request.nameFilter = filter
        }

        let response = try await client.listInterfaces(request).response.get()

        logger.debug("Listed interfaces", metadata: [
            "count": "\(response.interfaces.count)"
        ])

        return response.interfaces
    }
}

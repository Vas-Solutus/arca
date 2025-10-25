import Foundation
import GRPC
import Logging
import NIO
import NIOPosix
import Containerization
import ContainerizationOS

/// RouterClient handles gRPC communication with the Router service running in the helper VM.
/// This service manages VLAN interfaces, routing, NAT, DNS, and port forwarding for Docker bridge networks.
public actor RouterClient {
    private let logger: Logger
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Router_RouterServiceNIOClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public enum RouterClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case operationFailed(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "Router client not connected to helper VM"
            case .connectionFailed(let reason):
                return "Failed to connect to helper VM: \(reason)"
            case .operationFailed(let reason):
                return "Router operation failed: \(reason)"
            }
        }
    }

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "arca.network.routerclient")
    }

    /// Connect to the router service running in the helper VM via vsock.
    /// The service listens on vsock port 50052.
    public func connect(container: Containerization.LinuxContainer, vsockPort: UInt32 = 50052) async throws {
        logger.info("Connecting to router service via vsock (LinuxContainer.dialVsock())", metadata: [
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
        self.client = Router_RouterServiceNIOClient(channel: channel)

        logger.info("Connected to router service via vsock")
    }

    /// Disconnect from the helper VM router service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.info("Disconnecting from router service")

        try await channel.close().get()
        try await eventLoopGroup?.shutdownGracefully()

        self.channel = nil
        self.client = nil
        self.eventLoopGroup = nil
        self.vsockFileHandle = nil
    }

    // MARK: - VLAN Operations

    /// Create a VLAN interface in the helper VM for a Docker bridge network.
    ///
    /// - Parameters:
    ///   - vlanID: VLAN ID (100-4094, typically 100 + network index)
    ///   - subnet: Network subnet in CIDR notation (e.g., "172.18.0.0/16")
    ///   - gateway: Gateway IP address (e.g., "172.18.0.1")
    ///   - networkName: Docker network name for DNS configuration
    ///   - mtu: MTU size (default: 0 = use default)
    ///   - enableNAT: Enable NAT for outbound connectivity (default: true)
    ///
    /// - Returns: Created interface name (e.g., "eth0.100")
    /// - Throws: RouterClientError if not connected or operation fails
    public func createVLAN(
        vlanID: UInt32,
        subnet: String,
        gateway: String,
        networkName: String,
        mtu: UInt32 = 0,
        enableNAT: Bool = true
    ) async throws -> String {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_CreateVLANRequest()
        request.vlanID = vlanID
        request.subnet = subnet
        request.gateway = gateway
        request.networkName = networkName
        request.mtu = mtu
        request.enableNat = enableNAT

        logger.info("Creating VLAN network in helper VM", metadata: [
            "network": "\(networkName)",
            "vlan_id": "\(vlanID)",
            "subnet": "\(subnet)",
            "gateway": "\(gateway)"
        ])

        let response = try await client.createVLAN(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            logger.error("Failed to create VLAN network", metadata: [
                "network": "\(networkName)",
                "error": "\(error)"
            ])
            throw RouterClientError.operationFailed(error)
        }

        logger.info("VLAN network created successfully", metadata: [
            "network": "\(networkName)",
            "vlan_id": "\(vlanID)",
            "interface": "\(response.interfaceName)"
        ])

        return response.interfaceName
    }

    /// Delete a VLAN interface from the helper VM.
    ///
    /// - Parameter vlanID: VLAN ID to delete
    /// - Throws: RouterClientError if not connected or operation fails
    public func deleteVLAN(vlanID: UInt32) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_DeleteVLANRequest()
        request.vlanID = vlanID

        logger.info("Deleting VLAN network from helper VM", metadata: [
            "vlan_id": "\(vlanID)"
        ])

        let response = try await client.deleteVLAN(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            logger.error("Failed to delete VLAN network", metadata: [
                "vlan_id": "\(vlanID)",
                "error": "\(error)"
            ])
            throw RouterClientError.operationFailed(error)
        }

        logger.info("VLAN network deleted successfully", metadata: [
            "vlan_id": "\(vlanID)"
        ])
    }

    // MARK: - NAT Configuration

    /// Configure NAT (MASQUERADE) for a VLAN network.
    ///
    /// - Parameters:
    ///   - vlanID: VLAN ID
    ///   - sourceSubnet: Source subnet in CIDR notation (e.g., "172.18.0.0/16")
    ///
    /// - Throws: RouterClientError if not connected or operation fails
    public func configureNAT(
        vlanID: UInt32,
        sourceSubnet: String
    ) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_ConfigureNATRequest()
        request.vlanID = vlanID
        request.sourceSubnet = sourceSubnet

        let response = try await client.configureNAT(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw RouterClientError.operationFailed(error)
        }
    }

    /// Remove NAT rules for a VLAN network.
    ///
    /// - Parameters:
    ///   - vlanID: VLAN ID
    ///   - sourceSubnet: Source subnet that was NATed
    ///
    /// - Throws: RouterClientError if not connected or operation fails
    public func removeNAT(vlanID: UInt32, sourceSubnet: String) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_RemoveNATRequest()
        request.vlanID = vlanID
        request.sourceSubnet = sourceSubnet

        let response = try await client.removeNAT(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw RouterClientError.operationFailed(error)
        }
    }

    // MARK: - DNS Configuration

    /// Configure DNS for a VLAN network.
    ///
    /// - Parameters:
    ///   - vlanID: VLAN ID
    ///   - subnet: Network subnet (e.g., "172.18.0.0/16")
    ///   - gateway: Gateway IP address (DNS server will listen here)
    ///   - domain: DNS domain for container name resolution (e.g., "frontend.docker.internal")
    ///   - hosts: Container hostname → IP mappings
    ///
    /// - Throws: RouterClientError if not connected or operation fails
    public func configureDNS(
        vlanID: UInt32,
        subnet: String,
        gateway: String,
        domain: String,
        hosts: [String: String]
    ) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_ConfigureDNSRequest()
        request.vlanID = vlanID
        request.subnet = subnet
        request.gateway = gateway
        request.domain = domain
        request.hosts = hosts

        logger.debug("Configuring DNS for VLAN network", metadata: [
            "vlan_id": "\(vlanID)",
            "domain": "\(domain)",
            "host_count": "\(hosts.count)"
        ])

        let response = try await client.configureDNS(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw RouterClientError.operationFailed(error)
        }
    }

    // MARK: - Port Mapping

    /// Add a port mapping (DNAT rule) for host-to-container port forwarding.
    ///
    /// - Parameters:
    ///   - containerIP: Container IP address
    ///   - containerPort: Port on the container
    ///   - hostPort: Port on the host
    ///   - protocol: Protocol (tcp or udp)
    ///   - vlanID: VLAN ID (for routing back to container)
    ///
    /// - Throws: RouterClientError if not connected or operation fails
    public func addPortMapping(
        containerIP: String,
        containerPort: UInt32,
        hostPort: UInt32,
        protocol: String,
        vlanID: UInt32
    ) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_AddPortMappingRequest()
        request.containerIp = containerIP  // proto field: container_ip
        request.containerPort = containerPort
        request.hostPort = hostPort
        request.protocol = `protocol`
        request.vlanID = vlanID

        logger.info("Adding port mapping", metadata: [
            "vlan_id": "\(vlanID)",
            "mapping": "\(hostPort)/\(`protocol`) -> \(containerIP):\(containerPort)"
        ])

        let response = try await client.addPortMapping(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            logger.error("Failed to add port mapping", metadata: [
                "mapping": "\(hostPort)/\(`protocol`) -> \(containerIP):\(containerPort)",
                "error": "\(error)"
            ])
            throw RouterClientError.operationFailed(error)
        }

        logger.info("Port mapping added successfully", metadata: [
            "mapping": "\(hostPort)/\(`protocol`) -> \(containerIP):\(containerPort)"
        ])
    }

    /// Remove a port mapping.
    ///
    /// - Parameters:
    ///   - hostPort: Port on the host
    ///   - protocol: Protocol (tcp or udp)
    ///
    /// - Throws: RouterClientError if not connected or operation fails
    public func removePortMapping(
        hostPort: UInt32,
        protocol: String
    ) async throws {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_RemovePortMappingRequest()
        request.hostPort = hostPort
        request.protocol = `protocol`

        logger.info("Removing port mapping", metadata: [
            "mapping": "\(hostPort)/\(`protocol`)"
        ])

        let response = try await client.removePortMapping(request).response.get()

        if !response.success {
            let error = response.error.isEmpty ? "unknown error" : response.error
            throw RouterClientError.operationFailed(error)
        }
    }

    // MARK: - Query Operations

    /// List all VLAN networks in the helper VM.
    ///
    /// - Parameter vlanID: Optional filter by VLAN ID (0 = list all)
    /// - Returns: Array of VLAN network information
    /// - Throws: RouterClientError if not connected or operation fails
    public func listVLANs(vlanID: UInt32 = 0) async throws -> [Router_VLANInterface] {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        var request = Router_ListVLANsRequest()
        request.vlanID = vlanID

        let response = try await client.listVLANs(request).response.get()

        logger.debug("Listed VLANs", metadata: [
            "count": "\(response.vlans.count)"
        ])

        return response.vlans
    }

    /// Get health status of the router service.
    ///
    /// - Returns: Health information (status, uptime, active VLANs)
    /// - Throws: RouterClientError if not connected or operation fails
    public func getHealth() async throws -> Router_HealthResponse {
        guard let client = client else {
            throw RouterClientError.notConnected
        }

        let request = Router_HealthRequest()
        let response = try await client.getHealth(request).response.get()

        logger.debug("Router service health", metadata: [
            "healthy": "\(response.healthy)",
            "status": "\(response.status)",
            "active_vlans": "\(response.activeVlans)",
            "uptime": "\(response.uptimeSeconds)s"
        ])

        return response
    }
}

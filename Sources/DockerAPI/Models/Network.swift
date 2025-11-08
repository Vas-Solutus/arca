import Foundation

// MARK: - Docker API Network Models
// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md

/// Request for POST /networks/create endpoint
public struct NetworkCreateRequest: Codable {
    public let name: String
    public let checkDuplicate: Bool?
    public let driver: String?
    public let `internal`: Bool?
    public let attachable: Bool?
    public let ingress: Bool?
    public let ipam: IPAM?
    public let enableIPv6: Bool?
    public let options: [String: String]?
    public let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case checkDuplicate = "CheckDuplicate"
        case driver = "Driver"
        case `internal` = "Internal"
        case attachable = "Attachable"
        case ingress = "Ingress"
        case ipam = "IPAM"
        case enableIPv6 = "EnableIPv6"
        case options = "Options"
        case labels = "Labels"
    }
}

/// Response for POST /networks/create endpoint
public struct NetworkCreateResponse: Codable {
    public let id: String
    public let warning: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case warning = "Warning"
    }

    public init(id: String, warning: String? = nil) {
        self.id = id
        self.warning = warning
    }
}

/// Full network object for GET /networks/{id} and GET /networks
public struct Network: Codable {
    public let name: String
    public let id: String
    public let created: String
    public let scope: String
    public let driver: String
    public let enableIPv6: Bool
    public let ipam: IPAM
    public let `internal`: Bool
    public let attachable: Bool
    public let ingress: Bool
    public let containers: [String: NetworkContainer]
    public let options: [String: String]
    public let labels: [String: String]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case created = "Created"
        case scope = "Scope"
        case driver = "Driver"
        case enableIPv6 = "EnableIPv6"
        case ipam = "IPAM"
        case `internal` = "Internal"
        case attachable = "Attachable"
        case ingress = "Ingress"
        case containers = "Containers"
        case options = "Options"
        case labels = "Labels"
    }

    public init(
        name: String,
        id: String,
        created: String,
        scope: String = "local",
        driver: String,
        enableIPv6: Bool = false,
        ipam: IPAM,
        internal: Bool = false,
        attachable: Bool = false,
        ingress: Bool = false,
        containers: [String: NetworkContainer] = [:],
        options: [String: String] = [:],
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.id = id
        self.created = created
        self.scope = scope
        self.driver = driver
        self.enableIPv6 = enableIPv6
        self.ipam = ipam
        self.internal = `internal`
        self.attachable = attachable
        self.ingress = ingress
        self.containers = containers
        self.options = options
        self.labels = labels
    }
}

/// Container information within a network
public struct NetworkContainer: Codable {
    public let name: String
    public let endpointID: String
    public let macAddress: String
    public let ipv4Address: String
    public let ipv6Address: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case endpointID = "EndpointID"
        case macAddress = "MacAddress"
        case ipv4Address = "IPv4Address"
        case ipv6Address = "IPv6Address"
    }

    public init(
        name: String,
        endpointID: String,
        macAddress: String,
        ipv4Address: String,
        ipv6Address: String = ""
    ) {
        self.name = name
        self.endpointID = endpointID
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

/// IPAM (IP Address Management) configuration
public struct IPAM: Codable {
    public let driver: String?
    public let config: [IPAMConfig]?
    public let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case driver = "Driver"
        case config = "Config"
        case options = "Options"
    }

    public init(
        driver: String? = "default",
        config: [IPAMConfig]? = nil,
        options: [String: String]? = nil
    ) {
        self.driver = driver
        self.config = config
        self.options = options
    }
}

/// IPAM configuration for a subnet
public struct IPAMConfig: Codable {
    public let subnet: String?
    public let ipRange: String?
    public let gateway: String?
    public let auxAddress: [String: String]?

    enum CodingKeys: String, CodingKey {
        case subnet = "Subnet"
        case ipRange = "IPRange"
        case gateway = "Gateway"
        case auxAddress = "AuxAddress"
    }

    public init(
        subnet: String? = nil,
        ipRange: String? = nil,
        gateway: String? = nil,
        auxAddress: [String: String]? = nil
    ) {
        self.subnet = subnet
        self.ipRange = ipRange
        self.gateway = gateway
        self.auxAddress = auxAddress
    }
}

/// Request for POST /networks/{id}/connect endpoint
public struct NetworkConnectRequest: Codable {
    public let container: String
    public let endpointConfig: EndpointConfig?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case endpointConfig = "EndpointConfig"
    }
}

/// Request for POST /networks/{id}/disconnect endpoint
public struct NetworkDisconnectRequest: Codable {
    public let container: String
    public let force: Bool?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case force = "Force"
    }
}

/// Endpoint configuration for container network attachment
public struct EndpointConfig: Codable {
    public let ipamConfig: EndpointIPAMConfig?
    public let links: [String]?
    public let aliases: [String]?
    public let networkID: String?
    public let endpointID: String?
    public let gateway: String?
    public let ipAddress: String?
    public let ipPrefixLen: Int?
    public let ipv6Gateway: String?
    public let globalIPv6Address: String?
    public let globalIPv6PrefixLen: Int?
    public let macAddress: String?
    public let driverOpts: [String: String]?

    enum CodingKeys: String, CodingKey {
        case ipamConfig = "IPAMConfig"
        case links = "Links"
        case aliases = "Aliases"
        case networkID = "NetworkID"
        case endpointID = "EndpointID"
        case gateway = "Gateway"
        case ipAddress = "IPAddress"
        case ipPrefixLen = "IPPrefixLen"
        case ipv6Gateway = "IPv6Gateway"
        case globalIPv6Address = "GlobalIPv6Address"
        case globalIPv6PrefixLen = "GlobalIPv6PrefixLen"
        case macAddress = "MacAddress"
        case driverOpts = "DriverOpts"
    }
}

/// IPAM configuration for an endpoint
public struct EndpointIPAMConfig: Codable {
    public let ipv4Address: String?
    public let ipv6Address: String?
    public let linkLocalIPs: [String]?

    enum CodingKeys: String, CodingKey {
        case ipv4Address = "IPv4Address"
        case ipv6Address = "IPv6Address"
        case linkLocalIPs = "LinkLocalIPs"
    }
}

/// Response for POST /networks/prune endpoint
public struct NetworkPruneResponse: Codable {
    public let networksDeleted: [String]

    enum CodingKeys: String, CodingKey {
        case networksDeleted = "NetworksDeleted"
    }

    public init(networksDeleted: [String]) {
        self.networksDeleted = networksDeleted
    }
}

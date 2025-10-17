import Foundation

// MARK: - Docker API Container Models
// Reference: Documentation/DockerEngineAPIv1.51.yaml

/// Response for GET /containers/json endpoint
/// Returns an array of containers with their metadata
public struct ContainerListItem: Codable {
    public let id: String
    public let names: [String]
    public let image: String
    public let imageID: String
    public let command: String
    public let created: Int64
    public let state: String
    public let status: String
    public let ports: [Port]
    public let labels: [String: String]
    public let sizeRw: Int64?
    public let sizeRootFs: Int64?
    public let hostConfig: HostConfigSummary
    public let networkSettings: NetworkSettingsSummary
    public let mounts: [MountPoint]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case imageID = "ImageID"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
        case sizeRw = "SizeRw"
        case sizeRootFs = "SizeRootFs"
        case hostConfig = "HostConfig"
        case networkSettings = "NetworkSettings"
        case mounts = "Mounts"
    }

    public init(
        id: String,
        names: [String],
        image: String,
        imageID: String,
        command: String,
        created: Int64,
        state: String,
        status: String,
        ports: [Port] = [],
        labels: [String: String] = [:],
        sizeRw: Int64? = nil,
        sizeRootFs: Int64? = nil,
        hostConfig: HostConfigSummary = HostConfigSummary(networkMode: "default"),
        networkSettings: NetworkSettingsSummary = NetworkSettingsSummary(networks: [:]),
        mounts: [MountPoint] = []
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.imageID = imageID
        self.command = command
        self.created = created
        self.state = state
        self.status = status
        self.ports = ports
        self.labels = labels
        self.sizeRw = sizeRw
        self.sizeRootFs = sizeRootFs
        self.hostConfig = hostConfig
        self.networkSettings = networkSettings
        self.mounts = mounts
    }
}

/// Port information
public struct Port: Codable {
    public let privatePort: Int
    public let publicPort: Int?
    public let type: String
    public let ip: String?

    enum CodingKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
        case ip = "IP"
    }

    public init(privatePort: Int, publicPort: Int? = nil, type: String = "tcp", ip: String? = nil) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.type = type
        self.ip = ip
    }
}

/// Host configuration summary for list response
public struct HostConfigSummary: Codable {
    public let networkMode: String

    enum CodingKeys: String, CodingKey {
        case networkMode = "NetworkMode"
    }

    public init(networkMode: String) {
        self.networkMode = networkMode
    }
}

/// Network settings summary for list response
public struct NetworkSettingsSummary: Codable {
    public let networks: [String: NetworkEndpoint]

    enum CodingKeys: String, CodingKey {
        case networks = "Networks"
    }

    public init(networks: [String: NetworkEndpoint]) {
        self.networks = networks
    }
}

/// Network endpoint information
public struct NetworkEndpoint: Codable {
    public let networkID: String?
    public let endpointID: String?
    public let gateway: String?
    public let ipAddress: String?
    public let ipPrefixLen: Int?
    public let macAddress: String?

    enum CodingKeys: String, CodingKey {
        case networkID = "NetworkID"
        case endpointID = "EndpointID"
        case gateway = "Gateway"
        case ipAddress = "IPAddress"
        case ipPrefixLen = "IPPrefixLen"
        case macAddress = "MacAddress"
    }

    public init(
        networkID: String? = nil,
        endpointID: String? = nil,
        gateway: String? = nil,
        ipAddress: String? = nil,
        ipPrefixLen: Int? = nil,
        macAddress: String? = nil
    ) {
        self.networkID = networkID
        self.endpointID = endpointID
        self.gateway = gateway
        self.ipAddress = ipAddress
        self.ipPrefixLen = ipPrefixLen
        self.macAddress = macAddress
    }
}

/// Mount point information
public struct MountPoint: Codable {
    public let type: String
    public let name: String?
    public let source: String
    public let destination: String
    public let driver: String?
    public let mode: String
    public let rw: Bool
    public let propagation: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case name = "Name"
        case source = "Source"
        case destination = "Destination"
        case driver = "Driver"
        case mode = "Mode"
        case rw = "RW"
        case propagation = "Propagation"
    }

    public init(
        type: String,
        name: String? = nil,
        source: String,
        destination: String,
        driver: String? = nil,
        mode: String = "",
        rw: Bool = true,
        propagation: String = ""
    ) {
        self.type = type
        self.name = name
        self.source = source
        self.destination = destination
        self.driver = driver
        self.mode = mode
        self.rw = rw
        self.propagation = propagation
    }
}

// MARK: - Container Create Request/Response

/// Request body for POST /containers/create
public struct ContainerCreateRequest: Codable {
    public let hostname: String?
    public let domainname: String?
    public let user: String?
    public let attachStdin: Bool?
    public let attachStdout: Bool?
    public let attachStderr: Bool?
    public let tty: Bool?
    public let openStdin: Bool?
    public let stdinOnce: Bool?
    public let env: [String]?
    public let cmd: [String]?
    public let image: String
    public let volumes: [String: AnyCodable]?
    public let workingDir: String?
    public let entrypoint: [String]?
    public let labels: [String: String]?
    public let hostConfig: HostConfigCreate?

    enum CodingKeys: String, CodingKey {
        case hostname = "Hostname"
        case domainname = "Domainname"
        case user = "User"
        case attachStdin = "AttachStdin"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case tty = "Tty"
        case openStdin = "OpenStdin"
        case stdinOnce = "StdinOnce"
        case env = "Env"
        case cmd = "Cmd"
        case image = "Image"
        case volumes = "Volumes"
        case workingDir = "WorkingDir"
        case entrypoint = "Entrypoint"
        case labels = "Labels"
        case hostConfig = "HostConfig"
    }
}

/// Host configuration for container creation
public struct HostConfigCreate: Codable {
    public let binds: [String]?
    public let networkMode: String?
    public let portBindings: [String: [PortBindingCreate]]?
    public let restartPolicy: RestartPolicyCreate?
    public let autoRemove: Bool?
    public let privileged: Bool?

    enum CodingKeys: String, CodingKey {
        case binds = "Binds"
        case networkMode = "NetworkMode"
        case portBindings = "PortBindings"
        case restartPolicy = "RestartPolicy"
        case autoRemove = "AutoRemove"
        case privileged = "Privileged"
    }
}

/// Port binding for creation
public struct PortBindingCreate: Codable {
    public let hostIp: String?
    public let hostPort: String?

    enum CodingKeys: String, CodingKey {
        case hostIp = "HostIp"
        case hostPort = "HostPort"
    }
}

/// Restart policy for creation
public struct RestartPolicyCreate: Codable {
    public let name: String
    public let maximumRetryCount: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
    }
}

/// Response for POST /containers/create
public struct ContainerCreateResponse: Codable {
    public let id: String
    public let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case warnings = "Warnings"
    }

    public init(id: String, warnings: [String]? = nil) {
        self.id = id
        self.warnings = warnings
    }
}

// MARK: - Helper Types

/// Type-erased Codable wrapper for dynamic JSON values
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let dictValue as [String: Any]:
            let anyCodableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(anyCodableDict)
        case let arrayValue as [Any]:
            let anyCodableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(anyCodableArray)
        default:
            try container.encodeNil()
        }
    }
}

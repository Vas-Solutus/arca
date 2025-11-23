import Foundation

// MARK: - NetworkMetadata

/// Metadata for a Docker network
public struct NetworkMetadata: Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let subnet: String
    public let gateway: String
    public let ipRange: String?  // Optional IP range for IPAM (e.g., "172.18.0.128/25")
    public var containers: Set<String>
    public let created: Date
    public let options: [String: String]
    public let labels: [String: String]
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        driver: String,
        subnet: String,
        gateway: String,
        ipRange: String? = nil,
        containers: Set<String> = [],
        created: Date = Date(),
        options: [String: String] = [:],
        labels: [String: String] = [:],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.ipRange = ipRange
        self.containers = containers
        self.created = created
        self.options = options
        self.labels = labels
        self.isDefault = isDefault
    }
}

// MARK: - NetworkAttachment

/// Metadata for a container's network attachment
public struct NetworkAttachment: Sendable {
    public let networkID: String
    public let ip: String
    public let mac: String
    public let aliases: [String]

    public init(networkID: String, ip: String, mac: String, aliases: [String] = []) {
        self.networkID = networkID
        self.ip = ip
        self.mac = mac
        self.aliases = aliases
    }
}

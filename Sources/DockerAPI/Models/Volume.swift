import Foundation

// MARK: - Docker API Volume Models
// Reference: Documentation/DOCKER_ENGINE_v1.51.yaml

/// Request body for POST /volumes/create endpoint
/// Creates a new volume with the specified configuration
public struct VolumeCreateRequest: Codable {
    public let name: String?
    public let driver: String?
    public let driverOpts: [String: String]?
    public let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case driverOpts = "DriverOpts"
        case labels = "Labels"
    }

    public init(
        name: String? = nil,
        driver: String? = nil,
        driverOpts: [String: String]? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.driverOpts = driverOpts
        self.labels = labels
    }
}

/// Volume information returned by Docker API
/// Used for volume create, inspect, and list responses
public struct Volume: Codable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let createdAt: String?
    public let status: [String: AnyCodable]?
    public let labels: [String: String]
    public let scope: String
    public let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
        case status = "Status"
        case labels = "Labels"
        case scope = "Scope"
        case options = "Options"
    }

    public init(
        name: String,
        driver: String = "local",
        mountpoint: String,
        createdAt: String? = nil,
        status: [String: AnyCodable]? = nil,
        labels: [String: String] = [:],
        scope: String = "local",
        options: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.status = status
        self.labels = labels
        self.scope = scope
        self.options = options
    }
}

/// Response for GET /volumes endpoint
/// Returns list of volumes with optional warnings
public struct VolumeListResponse: Codable {
    public let volumes: [Volume]?
    public let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
        case warnings = "Warnings"
    }

    public init(volumes: [Volume]? = nil, warnings: [String]? = nil) {
        self.volumes = volumes
        self.warnings = warnings
    }
}

/// Response for POST /volumes/prune endpoint
/// Returns list of deleted volumes and space reclaimed
public struct VolumePruneResponse: Codable {
    public let volumesDeleted: [String]?
    public let spaceReclaimed: Int64

    enum CodingKeys: String, CodingKey {
        case volumesDeleted = "VolumesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }

    public init(volumesDeleted: [String]? = nil, spaceReclaimed: Int64 = 0) {
        self.volumesDeleted = volumesDeleted
        self.spaceReclaimed = spaceReclaimed
    }
}

// Note: AnyCodable is defined in Container.swift and reused here for volume status field

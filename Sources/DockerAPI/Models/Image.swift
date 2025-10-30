import Foundation

// MARK: - Docker API Image Models
// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md

/// Response for GET /images/json endpoint
public struct ImageListItem: Codable {
    public let id: String
    public let parentId: String
    public let repoTags: [String]?
    public let repoDigests: [String]?
    public let created: Int64
    public let size: Int64
    public let virtualSize: Int64
    public let sharedSize: Int64
    public let labels: [String: String]?
    public let containers: Int

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case parentId = "ParentId"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case virtualSize = "VirtualSize"
        case sharedSize = "SharedSize"
        case labels = "Labels"
        case containers = "Containers"
    }

    public init(
        id: String,
        parentId: String = "",
        repoTags: [String]? = nil,
        repoDigests: [String]? = nil,
        created: Int64,
        size: Int64,
        virtualSize: Int64,
        sharedSize: Int64 = 0,
        labels: [String: String]? = nil,
        containers: Int = -1
    ) {
        self.id = id
        self.parentId = parentId
        self.repoTags = repoTags
        self.repoDigests = repoDigests
        self.created = created
        self.size = size
        self.virtualSize = virtualSize
        self.sharedSize = sharedSize
        self.labels = labels
        self.containers = containers
    }
}

/// Response for GET /images/{name}/json endpoint
public struct ImageInspect: Codable {
    public let id: String
    public let repoTags: [String]?
    public let repoDigests: [String]?
    public let parent: String
    public let comment: String
    public let created: String  // ISO 8601 timestamp
    public let container: String?
    public let containerConfig: ImageConfig?
    public let dockerVersion: String
    public let author: String
    public let config: ImageConfig?
    public let architecture: String
    public let os: String
    public let size: Int64
    public let virtualSize: Int64
    public let graphDriver: ImageGraphDriver
    public let rootFS: ImageRootFS
    public let metadata: ImageMetadataResponse

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case parent = "Parent"
        case comment = "Comment"
        case created = "Created"
        case container = "Container"
        case containerConfig = "ContainerConfig"
        case dockerVersion = "DockerVersion"
        case author = "Author"
        case config = "Config"
        case architecture = "Architecture"
        case os = "Os"
        case size = "Size"
        case virtualSize = "VirtualSize"
        case graphDriver = "GraphDriver"
        case rootFS = "RootFS"
        case metadata = "Metadata"
    }

    public init(
        id: String,
        repoTags: [String]?,
        repoDigests: [String]?,
        parent: String,
        comment: String,
        created: String,
        container: String?,
        containerConfig: ImageConfig?,
        dockerVersion: String,
        author: String,
        config: ImageConfig?,
        architecture: String,
        os: String,
        size: Int64,
        virtualSize: Int64,
        graphDriver: ImageGraphDriver,
        rootFS: ImageRootFS,
        metadata: ImageMetadataResponse
    ) {
        self.id = id
        self.repoTags = repoTags
        self.repoDigests = repoDigests
        self.parent = parent
        self.comment = comment
        self.created = created
        self.container = container
        self.containerConfig = containerConfig
        self.dockerVersion = dockerVersion
        self.author = author
        self.config = config
        self.architecture = architecture
        self.os = os
        self.size = size
        self.virtualSize = virtualSize
        self.graphDriver = graphDriver
        self.rootFS = rootFS
        self.metadata = metadata
    }
}

/// Image configuration
public struct ImageConfig: Codable {
    public let hostname: String?
    public let domainname: String?
    public let user: String?
    public let attachStdin: Bool?
    public let attachStdout: Bool?
    public let attachStderr: Bool?
    public let exposedPorts: [String: AnyCodable]?
    public let tty: Bool?
    public let openStdin: Bool?
    public let stdinOnce: Bool?
    public let env: [String]?
    public let cmd: [String]?
    public let image: String?
    public let volumes: [String: AnyCodable]?
    public let workingDir: String?
    public let entrypoint: [String]?
    public let onBuild: [String]?
    public let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case hostname = "Hostname"
        case domainname = "Domainname"
        case user = "User"
        case attachStdin = "AttachStdin"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case exposedPorts = "ExposedPorts"
        case tty = "Tty"
        case openStdin = "OpenStdin"
        case stdinOnce = "StdinOnce"
        case env = "Env"
        case cmd = "Cmd"
        case image = "Image"
        case volumes = "Volumes"
        case workingDir = "WorkingDir"
        case entrypoint = "Entrypoint"
        case onBuild = "OnBuild"
        case labels = "Labels"
    }

    public init(
        hostname: String? = nil,
        domainname: String? = nil,
        user: String? = nil,
        attachStdin: Bool? = nil,
        attachStdout: Bool? = nil,
        attachStderr: Bool? = nil,
        exposedPorts: [String: AnyCodable]? = nil,
        tty: Bool? = nil,
        openStdin: Bool? = nil,
        stdinOnce: Bool? = nil,
        env: [String]? = nil,
        cmd: [String]? = nil,
        image: String? = nil,
        volumes: [String: AnyCodable]? = nil,
        workingDir: String? = nil,
        entrypoint: [String]? = nil,
        onBuild: [String]? = nil,
        labels: [String: String]? = nil
    ) {
        self.hostname = hostname
        self.domainname = domainname
        self.user = user
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.exposedPorts = exposedPorts
        self.tty = tty
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.env = env
        self.cmd = cmd
        self.image = image
        self.volumes = volumes
        self.workingDir = workingDir
        self.entrypoint = entrypoint
        self.onBuild = onBuild
        self.labels = labels
    }
}

/// Graph driver information
public struct ImageGraphDriver: Codable {
    public let name: String
    public let data: [String: String]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case data = "Data"
    }

    public init(name: String, data: [String: String] = [:]) {
        self.name = name
        self.data = data
    }
}

/// Root filesystem information
public struct ImageRootFS: Codable {
    public let type: String
    public let layers: [String]?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case layers = "Layers"
    }

    public init(type: String, layers: [String]? = nil) {
        self.type = type
        self.layers = layers
    }
}

/// Image metadata
public struct ImageMetadataResponse: Codable {
    public let lastTagTime: String?

    enum CodingKeys: String, CodingKey {
        case lastTagTime = "LastTagTime"
    }

    public init(lastTagTime: String? = nil) {
        self.lastTagTime = lastTagTime
    }
}

/// Response for DELETE /images/{name} endpoint
public struct ImageDeleteResponseItem: Codable {
    public let untagged: String?
    public let deleted: String?

    enum CodingKeys: String, CodingKey {
        case untagged = "Untagged"
        case deleted = "Deleted"
    }

    public init(untagged: String? = nil, deleted: String? = nil) {
        self.untagged = untagged
        self.deleted = deleted
    }
}

/// Response from image prune operation
public struct ImagePruneResponse: Codable {
    public let imagesDeleted: [ImageDeleteResponseItem]?
    public let spaceReclaimed: Int64

    enum CodingKeys: String, CodingKey {
        case imagesDeleted = "ImagesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }

    public init(imagesDeleted: [ImageDeleteResponseItem]?, spaceReclaimed: Int64) {
        self.imagesDeleted = imagesDeleted
        self.spaceReclaimed = spaceReclaimed
    }
}

/// Request for image pull authentication (X-Registry-Auth header)
public struct RegistryAuthConfig: Codable {
    public let username: String?
    public let password: String?
    public let email: String?
    public let serveraddress: String?
    public let identitytoken: String?
    public let registrytoken: String?

    public init(
        username: String? = nil,
        password: String? = nil,
        email: String? = nil,
        serveraddress: String? = nil,
        identitytoken: String? = nil,
        registrytoken: String? = nil
    ) {
        self.username = username
        self.password = password
        self.email = email
        self.serveraddress = serveraddress
        self.identitytoken = identitytoken
        self.registrytoken = registrytoken
    }

    /// Parse from base64-encoded JSON in X-Registry-Auth header
    public static func fromBase64(_ base64String: String) throws -> RegistryAuthConfig {
        guard let data = Data(base64Encoded: base64String) else {
            throw ImageError.invalidAuthHeader
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RegistryAuthConfig.self, from: data)
    }
}

// MARK: - Error Types

public enum ImageError: Error, CustomStringConvertible {
    case invalidAuthHeader
    case invalidReference(String)
    case imageNotFound(String)

    public var description: String {
        switch self {
        case .invalidAuthHeader:
            return "Invalid X-Registry-Auth header"
        case .invalidReference(let ref):
            return "Invalid image reference: \(ref)"
        case .imageNotFound(let ref):
            return "No such image: \(ref)"
        }
    }
}

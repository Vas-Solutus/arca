import Foundation

// MARK: - Bridging Types for Image Operations

/// Summary of an image for list operations
public struct ImageSummary {
    public let id: String  // Docker-style ID: sha256:abc123...
    public let repoTags: [String]  // e.g., ["nginx:latest", "nginx:1.21"]
    public let repoDigests: [String]  // e.g., ["nginx@sha256:..."]
    public let parent: String?  // Parent image ID
    public let comment: String
    public let created: Int64  // Unix timestamp
    public let size: Int64  // Size in bytes
    public let virtualSize: Int64  // Total size including shared layers
    public let sharedSize: Int64
    public let labels: [String: String]
    public let containers: Int

    public init(
        id: String,
        repoTags: [String],
        repoDigests: [String] = [],
        parent: String? = nil,
        comment: String = "",
        created: Int64,
        size: Int64,
        virtualSize: Int64,
        sharedSize: Int64 = 0,
        labels: [String: String] = [:],
        containers: Int = -1
    ) {
        self.id = id
        self.repoTags = repoTags
        self.repoDigests = repoDigests
        self.parent = parent
        self.comment = comment
        self.created = created
        self.size = size
        self.virtualSize = virtualSize
        self.sharedSize = sharedSize
        self.labels = labels
        self.containers = containers
    }
}

/// Detailed image information for inspect operations
public struct ImageDetails {
    public let id: String
    public let repoTags: [String]
    public let repoDigests: [String]
    public let parent: String?
    public let comment: String
    public let created: Date
    public let container: String?
    public let containerConfig: ImageContainerConfig?
    public let dockerVersion: String
    public let author: String
    public let config: ImageContainerConfig?
    public let architecture: String
    public let os: String
    public let size: Int64
    public let virtualSize: Int64
    public let graphDriver: GraphDriver
    public let rootFS: RootFS
    public let metadata: ImageMetadata

    public init(
        id: String,
        repoTags: [String],
        repoDigests: [String],
        parent: String?,
        comment: String,
        created: Date,
        container: String?,
        containerConfig: ImageContainerConfig?,
        dockerVersion: String,
        author: String,
        config: ImageContainerConfig?,
        architecture: String,
        os: String,
        size: Int64,
        virtualSize: Int64,
        graphDriver: GraphDriver,
        rootFS: RootFS,
        metadata: ImageMetadata
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

/// Image container configuration
public struct ImageContainerConfig {
    public let hostname: String
    public let domainname: String
    public let user: String
    public let attachStdin: Bool
    public let attachStdout: Bool
    public let attachStderr: Bool
    public let exposedPorts: [String: Any]?
    public let tty: Bool
    public let openStdin: Bool
    public let stdinOnce: Bool
    public let env: [String]
    public let cmd: [String]
    public let image: String?
    public let volumes: [String: Any]?
    public let workingDir: String
    public let entrypoint: [String]?
    public let onBuild: [String]?
    public let labels: [String: String]

    public init(
        hostname: String = "",
        domainname: String = "",
        user: String = "",
        attachStdin: Bool = false,
        attachStdout: Bool = false,
        attachStderr: Bool = false,
        exposedPorts: [String: Any]? = nil,
        tty: Bool = false,
        openStdin: Bool = false,
        stdinOnce: Bool = false,
        env: [String] = [],
        cmd: [String] = [],
        image: String? = nil,
        volumes: [String: Any]? = nil,
        workingDir: String = "",
        entrypoint: [String]? = nil,
        onBuild: [String]? = nil,
        labels: [String: String] = [:]
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
public struct GraphDriver {
    public let name: String
    public let data: [String: String]

    public init(name: String = "overlay2", data: [String: String] = [:]) {
        self.name = name
        self.data = data
    }
}

/// Root filesystem information
public struct RootFS {
    public let type: String
    public let layers: [String]

    public init(type: String = "layers", layers: [String] = []) {
        self.type = type
        self.layers = layers
    }
}

/// Image metadata
public struct ImageMetadata {
    public let lastTagTime: Date?

    public init(lastTagTime: Date? = nil) {
        self.lastTagTime = lastTagTime
    }
}

/// Image deletion response
public struct ImageDeleteItem {
    public let untagged: String?
    public let deleted: String?

    public init(untagged: String? = nil, deleted: String? = nil) {
        self.untagged = untagged
        self.deleted = deleted
    }
}

/// Authentication credentials for registry operations
public struct RegistryAuthentication {
    public let username: String?
    public let password: String?
    public let email: String?
    public let serverAddress: String?
    public let identityToken: String?
    public let registryToken: String?

    public init(
        username: String? = nil,
        password: String? = nil,
        email: String? = nil,
        serverAddress: String? = nil,
        identityToken: String? = nil,
        registryToken: String? = nil
    ) {
        self.username = username
        self.password = password
        self.email = email
        self.serverAddress = serverAddress
        self.identityToken = identityToken
        self.registryToken = registryToken
    }
}

/// Image reference parser
public struct ImageReference {
    public let registry: String?
    public let namespace: String?
    public let repository: String
    public let tag: String
    public let digest: String?

    public init(registry: String? = nil, namespace: String? = nil, repository: String, tag: String = "latest", digest: String? = nil) {
        self.registry = registry
        self.namespace = namespace
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Parse a Docker image reference
    /// Examples:
    ///   nginx:latest -> ImageReference(repository: "nginx", tag: "latest")
    ///   docker.io/library/nginx:1.21 -> ImageReference(registry: "docker.io", namespace: "library", repository: "nginx", tag: "1.21")
    ///   nginx@sha256:abc -> ImageReference(repository: "nginx", digest: "sha256:abc")
    public static func parse(_ reference: String) -> ImageReference {
        var remaining = reference

        // Extract digest if present
        var digest: String?
        if let atIndex = remaining.firstIndex(of: "@") {
            digest = String(remaining[remaining.index(after: atIndex)...])
            remaining = String(remaining[..<atIndex])
        }

        // Extract tag if present (and no digest)
        var tag = "latest"
        if digest == nil, let colonIndex = remaining.lastIndex(of: ":") {
            // Make sure it's not part of the registry (e.g., localhost:5000)
            let afterColon = String(remaining[remaining.index(after: colonIndex)...])
            if !afterColon.contains("/") {
                tag = afterColon
                remaining = String(remaining[..<colonIndex])
            }
        }

        // Split into components
        let components = remaining.split(separator: "/").map(String.init)

        var registry: String?
        var namespace: String?
        var repository: String

        switch components.count {
        case 1:
            // Just repository: nginx
            repository = components[0]
        case 2:
            // namespace/repository: library/nginx
            // OR registry/repository: localhost:5000/nginx
            if components[0].contains(".") || components[0].contains(":") {
                registry = components[0]
                repository = components[1]
            } else {
                namespace = components[0]
                repository = components[1]
            }
        case 3:
            // registry/namespace/repository: docker.io/library/nginx
            registry = components[0]
            namespace = components[1]
            repository = components[2]
        default:
            // More complex: take last as repository, second-to-last as namespace, rest as registry
            registry = components.dropLast(2).joined(separator: "/")
            namespace = components[components.count - 2]
            repository = components.last!
        }

        return ImageReference(
            registry: registry,
            namespace: namespace,
            repository: repository,
            tag: tag,
            digest: digest
        )
    }

    /// Convert to full reference string
    public var fullReference: String {
        var parts: [String] = []

        if let registry = registry {
            parts.append(registry)
        }

        if let namespace = namespace {
            parts.append(namespace)
        }

        parts.append(repository)

        var result = parts.joined(separator: "/")

        if let digest = digest {
            result += "@\(digest)"
        } else {
            result += ":\(tag)"
        }

        return result
    }
}

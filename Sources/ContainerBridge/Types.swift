import Foundation

// MARK: - Bridging Types between Docker API and Containerization

/// Summary of a container for list operations
public struct ContainerSummary: Sendable {
    public let id: String  // Docker-style 64-char hex ID
    public let nativeID: String  // Apple Containerization ID (UUID or similar)
    public let names: [String]
    public let image: String
    public let imageID: String
    public let command: String
    public let created: Int64  // Unix timestamp
    public let state: String  // "created", "running", "paused", "restarting", "removing", "exited", "dead"
    public let status: String  // Human-readable status like "Up 2 hours"
    public let ports: [PortMapping]
    public let labels: [String: String]
    public let sizeRw: Int64?
    public let sizeRootFs: Int64?

    public init(
        id: String,
        nativeID: String,
        names: [String],
        image: String,
        imageID: String,
        command: String,
        created: Int64,
        state: String,
        status: String,
        ports: [PortMapping] = [],
        labels: [String: String] = [:],
        sizeRw: Int64? = nil,
        sizeRootFs: Int64? = nil
    ) {
        self.id = id
        self.nativeID = nativeID
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
    }
}

/// Port mapping information
public struct PortMapping: Sendable {
    public let privatePort: Int
    public let publicPort: Int?
    public let type: String  // "tcp" or "udp"
    public let ip: String?

    public init(privatePort: Int, publicPort: Int? = nil, type: String = "tcp", ip: String? = nil) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.type = type
        self.ip = ip
    }
}

/// Full container details
public struct Container: Sendable {
    public let id: String
    public let nativeID: String
    public let created: Date
    public let path: String
    public let args: [String]
    public let state: ContainerState
    public let image: String
    public let name: String
    public let restartCount: Int
    public let hostConfig: HostConfig
    public let config: ContainerConfiguration
    public let networkSettings: NetworkSettings

    public init(
        id: String,
        nativeID: String,
        created: Date,
        path: String,
        args: [String],
        state: ContainerState,
        image: String,
        name: String,
        restartCount: Int,
        hostConfig: HostConfig,
        config: ContainerConfiguration,
        networkSettings: NetworkSettings
    ) {
        self.id = id
        self.nativeID = nativeID
        self.created = created
        self.path = path
        self.args = args
        self.state = state
        self.image = image
        self.name = name
        self.restartCount = restartCount
        self.hostConfig = hostConfig
        self.config = config
        self.networkSettings = networkSettings
    }
}

/// Container runtime state
public struct ContainerState: Sendable {
    public let status: String
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let oomKilled: Bool
    public let dead: Bool
    public let pid: Int
    public let exitCode: Int
    public let error: String
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(
        status: String,
        running: Bool,
        paused: Bool,
        restarting: Bool,
        oomKilled: Bool,
        dead: Bool,
        pid: Int,
        exitCode: Int,
        error: String,
        startedAt: Date?,
        finishedAt: Date?
    ) {
        self.status = status
        self.running = running
        self.paused = paused
        self.restarting = restarting
        self.oomKilled = oomKilled
        self.dead = dead
        self.pid = pid
        self.exitCode = exitCode
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Container configuration
public struct ContainerConfiguration: @unchecked Sendable {
    public let hostname: String
    public let domainname: String
    public let user: String
    public let attachStdin: Bool
    public let attachStdout: Bool
    public let attachStderr: Bool
    public let tty: Bool
    public let openStdin: Bool
    public let stdinOnce: Bool
    public let env: [String]
    public let cmd: [String]
    public let image: String
    public let volumes: [String: Any]  // Not directly Codable - handled in extension
    public let workingDir: String
    public let entrypoint: [String]?
    public let labels: [String: String]

    public init(
        hostname: String = "",
        domainname: String = "",
        user: String = "",
        attachStdin: Bool = false,
        attachStdout: Bool = true,
        attachStderr: Bool = true,
        tty: Bool = false,
        openStdin: Bool = false,
        stdinOnce: Bool = false,
        env: [String] = [],
        cmd: [String] = [],
        image: String,
        volumes: [String: Any] = [:],
        workingDir: String = "",
        entrypoint: [String]? = nil,
        labels: [String: String] = [:]
    ) {
        self.hostname = hostname
        self.domainname = domainname
        self.user = user
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.tty = tty
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.env = env
        self.cmd = cmd
        self.image = image
        self.volumes = volumes
        self.workingDir = workingDir
        self.entrypoint = entrypoint
        self.labels = labels
    }
}

/// Host configuration for containers
public struct HostConfig: Sendable {
    public let binds: [String]
    public let networkMode: String
    public let portBindings: [String: [PortBinding]]
    public let restartPolicy: RestartPolicy
    public let autoRemove: Bool
    public let volumeDriver: String
    public let privileged: Bool

    // Memory Limits (Phase 5 - Task 5.1)
    public let memory: Int64
    public let memoryReservation: Int64
    public let memorySwap: Int64
    public let memorySwappiness: Int

    // CPU Limits (Phase 5 - Task 5.2)
    public let nanoCpus: Int64
    public let cpuShares: Int64
    public let cpuPeriod: Int64
    public let cpuQuota: Int64
    public let cpusetCpus: String
    public let cpusetMems: String

    // User/UID Support (Phase 5 - Task 5.3)
    public let groupAdd: [String]

    // Security Capabilities (Phase 5 - Task 5.5)
    public let capAdd: [String]
    public let capDrop: [String]
    public let securityOpt: [String]

    public init(
        binds: [String] = [],
        networkMode: String = "default",
        portBindings: [String: [PortBinding]] = [:],
        restartPolicy: RestartPolicy = RestartPolicy(name: "no"),
        autoRemove: Bool = false,
        volumeDriver: String = "",
        privileged: Bool = false,
        memory: Int64 = 0,
        memoryReservation: Int64 = 0,
        memorySwap: Int64 = 0,
        memorySwappiness: Int = -1,
        nanoCpus: Int64 = 0,
        cpuShares: Int64 = 0,
        cpuPeriod: Int64 = 0,
        cpuQuota: Int64 = 0,
        cpusetCpus: String = "",
        cpusetMems: String = "",
        groupAdd: [String] = [],
        capAdd: [String] = [],
        capDrop: [String] = [],
        securityOpt: [String] = []
    ) {
        self.binds = binds
        self.networkMode = networkMode
        self.portBindings = portBindings
        self.restartPolicy = restartPolicy
        self.autoRemove = autoRemove
        self.volumeDriver = volumeDriver
        self.privileged = privileged
        self.memory = memory
        self.memoryReservation = memoryReservation
        self.memorySwap = memorySwap
        self.memorySwappiness = memorySwappiness
        self.nanoCpus = nanoCpus
        self.cpuShares = cpuShares
        self.cpuPeriod = cpuPeriod
        self.cpuQuota = cpuQuota
        self.cpusetCpus = cpusetCpus
        self.cpusetMems = cpusetMems
        self.groupAdd = groupAdd
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.securityOpt = securityOpt
    }
}

/// Port binding for host configuration
public struct PortBinding: Codable, Sendable {
    public let hostIp: String
    public let hostPort: String

    public init(hostIp: String = "0.0.0.0", hostPort: String) {
        self.hostIp = hostIp
        self.hostPort = hostPort
    }
}

/// Restart policy
public struct RestartPolicy: Codable, Sendable {
    public let name: String  // "no", "always", "on-failure", "unless-stopped"
    public let maximumRetryCount: Int

    public init(name: String, maximumRetryCount: Int = 0) {
        self.name = name
        self.maximumRetryCount = maximumRetryCount
    }
}

/// Network settings
public struct NetworkSettings: Sendable {
    public let bridge: String
    public let sandboxID: String
    public let hairpinMode: Bool
    public let linkLocalIPv6Address: String
    public let linkLocalIPv6PrefixLen: Int
    public let ports: [String: [PortBinding]?]
    public let sandboxKey: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let gateway: String
    public let macAddress: String
    public let networks: [String: EndpointSettings]

    public init(
        bridge: String = "",
        sandboxID: String = "",
        hairpinMode: Bool = false,
        linkLocalIPv6Address: String = "",
        linkLocalIPv6PrefixLen: Int = 0,
        ports: [String: [PortBinding]?] = [:],
        sandboxKey: String = "",
        ipAddress: String = "",
        ipPrefixLen: Int = 0,
        gateway: String = "",
        macAddress: String = "",
        networks: [String: EndpointSettings] = [:]
    ) {
        self.bridge = bridge
        self.sandboxID = sandboxID
        self.hairpinMode = hairpinMode
        self.linkLocalIPv6Address = linkLocalIPv6Address
        self.linkLocalIPv6PrefixLen = linkLocalIPv6PrefixLen
        self.ports = ports
        self.sandboxKey = sandboxKey
        self.ipAddress = ipAddress
        self.ipPrefixLen = ipPrefixLen
        self.gateway = gateway
        self.macAddress = macAddress
        self.networks = networks
    }
}

/// Network endpoint settings
public struct EndpointSettings: Sendable {
    public let ipamConfig: IPAMConfig?
    public let links: [String]
    public let aliases: [String]
    public let networkID: String
    public let endpointID: String
    public let gateway: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let macAddress: String

    public init(
        ipamConfig: IPAMConfig? = nil,
        links: [String] = [],
        aliases: [String] = [],
        networkID: String = "",
        endpointID: String = "",
        gateway: String = "",
        ipAddress: String = "",
        ipPrefixLen: Int = 0,
        macAddress: String = ""
    ) {
        self.ipamConfig = ipamConfig
        self.links = links
        self.aliases = aliases
        self.networkID = networkID
        self.endpointID = endpointID
        self.gateway = gateway
        self.ipAddress = ipAddress
        self.ipPrefixLen = ipPrefixLen
        self.macAddress = macAddress
    }
}

/// IPAM configuration
public struct IPAMConfig: Sendable {
    public let ipv4Address: String
    public let ipv6Address: String

    public init(ipv4Address: String = "", ipv6Address: String = "") {
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

// MARK: - Codable Conformance

extension ContainerConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case hostname, domainname, user
        case attachStdin, attachStdout, attachStderr
        case tty, openStdin, stdinOnce
        case env, cmd, image, workingDir, entrypoint, labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decode(String.self, forKey: .hostname)
        domainname = try container.decode(String.self, forKey: .domainname)
        user = try container.decode(String.self, forKey: .user)
        attachStdin = try container.decode(Bool.self, forKey: .attachStdin)
        attachStdout = try container.decode(Bool.self, forKey: .attachStdout)
        attachStderr = try container.decode(Bool.self, forKey: .attachStderr)
        tty = try container.decode(Bool.self, forKey: .tty)
        openStdin = try container.decode(Bool.self, forKey: .openStdin)
        stdinOnce = try container.decode(Bool.self, forKey: .stdinOnce)
        env = try container.decode([String].self, forKey: .env)
        cmd = try container.decode([String].self, forKey: .cmd)
        image = try container.decode(String.self, forKey: .image)
        workingDir = try container.decode(String.self, forKey: .workingDir)
        entrypoint = try container.decodeIfPresent([String].self, forKey: .entrypoint)
        labels = try container.decode([String: String].self, forKey: .labels)
        volumes = [:]  // Not persisted for now
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(domainname, forKey: .domainname)
        try container.encode(user, forKey: .user)
        try container.encode(attachStdin, forKey: .attachStdin)
        try container.encode(attachStdout, forKey: .attachStdout)
        try container.encode(attachStderr, forKey: .attachStderr)
        try container.encode(tty, forKey: .tty)
        try container.encode(openStdin, forKey: .openStdin)
        try container.encode(stdinOnce, forKey: .stdinOnce)
        try container.encode(env, forKey: .env)
        try container.encode(cmd, forKey: .cmd)
        try container.encode(image, forKey: .image)
        try container.encode(workingDir, forKey: .workingDir)
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encode(labels, forKey: .labels)
        // volumes intentionally not encoded (not supported for persistence yet)
    }
}

extension HostConfig: Codable {
    // Codable synthesized automatically since all properties are Codable
}

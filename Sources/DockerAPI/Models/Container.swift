import Foundation

// MARK: - Docker API Container Models
// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md

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
public struct ContainerCreateRequest: Codable, Sendable {
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
    public let networkingConfig: NetworkingConfig?  // For docker run --ip support

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
        case networkingConfig = "NetworkingConfig"
    }
}

/// Host configuration for container creation
public struct HostConfigCreate: Codable, Sendable {
    public let binds: [String]?
    public let networkMode: String?
    public let portBindings: [String: [PortBindingCreate]]?
    public let restartPolicy: RestartPolicyCreate?
    public let autoRemove: Bool?
    public let privileged: Bool?

    // Memory Limits (Phase 5 - Task 5.1)
    public let memory: Int64?              // --memory in bytes
    public let memoryReservation: Int64?   // --memory-reservation (soft limit)
    public let memorySwap: Int64?          // --memory-swap (-1 = unlimited)
    public let memorySwappiness: Int?      // 0-100, -1 = use system default
    public let shmSize: Int64?             // /dev/shm size in bytes

    // CPU Limits (Phase 5 - Task 5.2)
    public let nanoCpus: Int64?            // --cpus as nanocpus (e.g., 1.5 CPUs = 1500000000)
    public let cpuShares: Int64?           // -c, --cpu-shares (relative weight, default: 1024)
    public let cpuPeriod: Int64?           // --cpu-period (CPU CFS period in microseconds)
    public let cpuQuota: Int64?            // --cpu-quota (CPU CFS quota in microseconds)
    public let cpusetCpus: String?         // --cpuset-cpus (CPUs allowed: "0-3,5")
    public let cpusetMems: String?         // --cpuset-mems (Memory nodes: "0,1")

    enum CodingKeys: String, CodingKey {
        case binds = "Binds"
        case networkMode = "NetworkMode"
        case portBindings = "PortBindings"
        case restartPolicy = "RestartPolicy"
        case autoRemove = "AutoRemove"
        case privileged = "Privileged"
        case memory = "Memory"
        case memoryReservation = "MemoryReservation"
        case memorySwap = "MemorySwap"
        case memorySwappiness = "MemorySwappiness"
        case shmSize = "ShmSize"
        case nanoCpus = "NanoCpus"
        case cpuShares = "CpuShares"
        case cpuPeriod = "CpuPeriod"
        case cpuQuota = "CpuQuota"
        case cpusetCpus = "CpusetCpus"
        case cpusetMems = "CpusetMems"
    }
}

/// Port binding for creation
public struct PortBindingCreate: Codable, Sendable {
    public let hostIp: String?
    public let hostPort: String?

    enum CodingKeys: String, CodingKey {
        case hostIp = "HostIp"
        case hostPort = "HostPort"
    }
}

/// Restart policy for creation
public struct RestartPolicyCreate: Codable, Sendable {
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

// MARK: - Container Inspect Response

/// Response for GET /containers/{id}/json endpoint
/// Full container details including state, config, and network settings
public struct ContainerInspect: Codable {
    public let id: String
    public let created: String  // ISO 8601 timestamp
    public let path: String
    public let args: [String]
    public let state: ContainerStateInspect
    public let image: String
    public let resolvConfPath: String
    public let hostnamePath: String
    public let hostsPath: String
    public let logPath: String
    public let name: String
    public let restartCount: Int
    public let driver: String
    public let platform: String
    public let mountLabel: String
    public let processLabel: String
    public let appArmorProfile: String
    public let hostConfig: HostConfigInspect
    public let config: ContainerConfigInspect
    public let networkSettings: NetworkSettingsInspect
    public let mounts: [MountInspect]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case path = "Path"
        case args = "Args"
        case state = "State"
        case image = "Image"
        case resolvConfPath = "ResolvConfPath"
        case hostnamePath = "HostnamePath"
        case hostsPath = "HostsPath"
        case logPath = "LogPath"
        case name = "Name"
        case restartCount = "RestartCount"
        case driver = "Driver"
        case platform = "Platform"
        case mountLabel = "MountLabel"
        case processLabel = "ProcessLabel"
        case appArmorProfile = "AppArmorProfile"
        case hostConfig = "HostConfig"
        case config = "Config"
        case networkSettings = "NetworkSettings"
        case mounts = "Mounts"
    }

    public init(
        id: String,
        created: String,
        path: String,
        args: [String],
        state: ContainerStateInspect,
        image: String,
        resolvConfPath: String = "",
        hostnamePath: String = "",
        hostsPath: String = "",
        logPath: String = "",
        name: String,
        restartCount: Int = 0,
        driver: String = "overlay2",
        platform: String = "linux",
        mountLabel: String = "",
        processLabel: String = "",
        appArmorProfile: String = "",
        hostConfig: HostConfigInspect,
        config: ContainerConfigInspect,
        networkSettings: NetworkSettingsInspect,
        mounts: [MountInspect] = []
    ) {
        self.id = id
        self.created = created
        self.path = path
        self.args = args
        self.state = state
        self.image = image
        self.resolvConfPath = resolvConfPath
        self.hostnamePath = hostnamePath
        self.hostsPath = hostsPath
        self.logPath = logPath
        self.name = name
        self.restartCount = restartCount
        self.driver = driver
        self.platform = platform
        self.mountLabel = mountLabel
        self.processLabel = processLabel
        self.appArmorProfile = appArmorProfile
        self.hostConfig = hostConfig
        self.config = config
        self.networkSettings = networkSettings
        self.mounts = mounts
    }
}

/// Container state for inspect response
public struct ContainerStateInspect: Codable {
    public let status: String
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let oomKilled: Bool
    public let dead: Bool
    public let pid: Int
    public let exitCode: Int
    public let error: String
    public let startedAt: String
    public let finishedAt: String

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case paused = "Paused"
        case restarting = "Restarting"
        case oomKilled = "OOMKilled"
        case dead = "Dead"
        case pid = "Pid"
        case exitCode = "ExitCode"
        case error = "Error"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
    }

    public init(
        status: String,
        running: Bool,
        paused: Bool = false,
        restarting: Bool = false,
        oomKilled: Bool = false,
        dead: Bool = false,
        pid: Int,
        exitCode: Int,
        error: String = "",
        startedAt: String,
        finishedAt: String
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

/// Host config for inspect response
public struct HostConfigInspect: Codable {
    public let binds: [String]?
    public let networkMode: String
    public let portBindings: [String: [PortBindingInspect]]?
    public let restartPolicy: RestartPolicyInspect
    public let autoRemove: Bool
    public let privileged: Bool

    // Memory Limits (Phase 5 - Task 5.1)
    public let memory: Int64
    public let memoryReservation: Int64
    public let memorySwap: Int64
    public let memorySwappiness: Int
    public let shmSize: Int64

    // CPU Limits (Phase 5 - Task 5.2)
    public let nanoCpus: Int64
    public let cpuShares: Int64
    public let cpuPeriod: Int64
    public let cpuQuota: Int64
    public let cpusetCpus: String
    public let cpusetMems: String

    enum CodingKeys: String, CodingKey {
        case binds = "Binds"
        case networkMode = "NetworkMode"
        case portBindings = "PortBindings"
        case restartPolicy = "RestartPolicy"
        case autoRemove = "AutoRemove"
        case privileged = "Privileged"
        case memory = "Memory"
        case memoryReservation = "MemoryReservation"
        case memorySwap = "MemorySwap"
        case memorySwappiness = "MemorySwappiness"
        case shmSize = "ShmSize"
        case nanoCpus = "NanoCpus"
        case cpuShares = "CpuShares"
        case cpuPeriod = "CpuPeriod"
        case cpuQuota = "CpuQuota"
        case cpusetCpus = "CpusetCpus"
        case cpusetMems = "CpusetMems"
    }

    public init(
        binds: [String]? = nil,
        networkMode: String = "default",
        portBindings: [String: [PortBindingInspect]]? = nil,
        restartPolicy: RestartPolicyInspect = RestartPolicyInspect(name: "no"),
        autoRemove: Bool = false,
        privileged: Bool = false,
        memory: Int64 = 0,
        memoryReservation: Int64 = 0,
        memorySwap: Int64 = 0,
        memorySwappiness: Int = -1,
        shmSize: Int64 = 67108864,  // Default: 64MB
        nanoCpus: Int64 = 0,
        cpuShares: Int64 = 0,
        cpuPeriod: Int64 = 0,
        cpuQuota: Int64 = 0,
        cpusetCpus: String = "",
        cpusetMems: String = ""
    ) {
        self.binds = binds
        self.networkMode = networkMode
        self.portBindings = portBindings
        self.restartPolicy = restartPolicy
        self.autoRemove = autoRemove
        self.privileged = privileged
        self.memory = memory
        self.memoryReservation = memoryReservation
        self.memorySwap = memorySwap
        self.memorySwappiness = memorySwappiness
        self.shmSize = shmSize
        self.nanoCpus = nanoCpus
        self.cpuShares = cpuShares
        self.cpuPeriod = cpuPeriod
        self.cpuQuota = cpuQuota
        self.cpusetCpus = cpusetCpus
        self.cpusetMems = cpusetMems
    }
}

/// Port binding for inspect response
public struct PortBindingInspect: Codable {
    public let hostIp: String
    public let hostPort: String

    enum CodingKeys: String, CodingKey {
        case hostIp = "HostIp"
        case hostPort = "HostPort"
    }

    public init(hostIp: String = "", hostPort: String = "") {
        self.hostIp = hostIp
        self.hostPort = hostPort
    }
}

/// Restart policy for inspect response
public struct RestartPolicyInspect: Codable {
    public let name: String
    public let maximumRetryCount: Int

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
    }

    public init(name: String, maximumRetryCount: Int = 0) {
        self.name = name
        self.maximumRetryCount = maximumRetryCount
    }
}

/// Container config for inspect response
public struct ContainerConfigInspect: Codable {
    public let hostname: String
    public let domainname: String
    public let user: String
    public let attachStdin: Bool
    public let attachStdout: Bool
    public let attachStderr: Bool
    public let tty: Bool
    public let openStdin: Bool
    public let stdinOnce: Bool
    public let env: [String]?
    public let cmd: [String]?
    public let image: String
    public let volumes: [String: AnyCodable]?
    public let workingDir: String
    public let entrypoint: [String]?
    public let labels: [String: String]?

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
    }

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
        env: [String]? = nil,
        cmd: [String]? = nil,
        image: String,
        volumes: [String: AnyCodable]? = nil,
        workingDir: String = "",
        entrypoint: [String]? = nil,
        labels: [String: String]? = nil
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

/// Network settings for inspect response
public struct NetworkSettingsInspect: Codable {
    public let bridge: String
    public let sandboxID: String
    public let hairpinMode: Bool
    public let linkLocalIPv6Address: String
    public let linkLocalIPv6PrefixLen: Int
    public let ports: [String: [PortBindingInspect]?]?
    public let sandboxKey: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let gateway: String
    public let macAddress: String
    public let networks: [String: NetworkEndpointInspect]

    enum CodingKeys: String, CodingKey {
        case bridge = "Bridge"
        case sandboxID = "SandboxID"
        case hairpinMode = "HairpinMode"
        case linkLocalIPv6Address = "LinkLocalIPv6Address"
        case linkLocalIPv6PrefixLen = "LinkLocalIPv6PrefixLen"
        case ports = "Ports"
        case sandboxKey = "SandboxKey"
        case ipAddress = "IPAddress"
        case ipPrefixLen = "IPPrefixLen"
        case gateway = "Gateway"
        case macAddress = "MacAddress"
        case networks = "Networks"
    }

    public init(
        bridge: String = "",
        sandboxID: String = "",
        hairpinMode: Bool = false,
        linkLocalIPv6Address: String = "",
        linkLocalIPv6PrefixLen: Int = 0,
        ports: [String: [PortBindingInspect]?]? = nil,
        sandboxKey: String = "",
        ipAddress: String = "",
        ipPrefixLen: Int = 0,
        gateway: String = "",
        macAddress: String = "",
        networks: [String: NetworkEndpointInspect] = [:]
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

/// Network endpoint for inspect response
public struct NetworkEndpointInspect: Codable {
    public let networkID: String
    public let endpointID: String
    public let gateway: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let macAddress: String

    enum CodingKeys: String, CodingKey {
        case networkID = "NetworkID"
        case endpointID = "EndpointID"
        case gateway = "Gateway"
        case ipAddress = "IPAddress"
        case ipPrefixLen = "IPPrefixLen"
        case macAddress = "MacAddress"
    }

    public init(
        networkID: String = "",
        endpointID: String = "",
        gateway: String = "",
        ipAddress: String = "",
        ipPrefixLen: Int = 0,
        macAddress: String = ""
    ) {
        self.networkID = networkID
        self.endpointID = endpointID
        self.gateway = gateway
        self.ipAddress = ipAddress
        self.ipPrefixLen = ipPrefixLen
        self.macAddress = macAddress
    }
}

/// Mount information for inspect response
public struct MountInspect: Codable {
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

// MARK: - Helper Types

/// Type-erased Codable wrapper for dynamic JSON values
public struct AnyCodable: Codable, @unchecked Sendable {
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
